#!/usr/bin/env python3
"""Generate the Ghostmap origin marker.

The marker is a 20 x 20 cm high-contrast binary pattern that ARKit tracks as an
`ARReferenceImage` (see `App/Capture/MarkerReference.swift`).  Layout, in units of
1/100 of the marker width (2 mm at 20 cm, 20 px at 2000 px):

    0 .. 6    white quiet zone       (12 mm)
    6 .. 12   solid black border     (12 mm)
   12 .. 14   white separator        ( 4 mm, keeps payload cells off the border)
   14 .. 86   8 x 8 payload cells    (144 mm, 18 mm per cell)
   86 .. 88   white separator
   88 .. 94   solid black border
   94 .. 100  white quiet zone

The payload is a fixed, seeded, random-looking bit grid: the top-left 2 x 2 block
is forced black and the other three corner blocks white, which makes the pattern
distinguishable from all three of its rotations (the orientation corner), and the
remaining 48 cells come from a self-contained xorshift64* PRNG so the output does
not depend on the Python version.  The generator retries until the grid is
balanced, rotationally unique, spread over every row and column and free of
uniform 3 x 3 blocks (large flat areas are what makes ARKit call a reference
image low-quality), so every run of this script on every machine produces
byte-identical files.

Outputs
  App/Marker/ghostmap-marker.png   2000 x 2000 8-bit RGB, pHYs = 10000 px/m
                                   (so "print at 100 %" gives exactly 20 cm)
  docs/ghostmap-marker.pdf         A4 page with the marker at exactly 20 cm plus
                                   a measuring bar; skip with --no-pdf

Usage
  python3 scripts/make-marker.py [--seed N] [--size PX] [--no-pdf] [--check]

  --check regenerates into memory and compares with the files on disk, exiting
  non-zero when they differ (useful in CI).

Stdlib only: zlib, struct, argparse, pathlib.
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path

# --- Geometry, in units of 1/100 of the marker width -------------------------

UNITS = 100
QUIET = 6          # white margin around the black border
BORDER = 6         # black border ring thickness
SEPARATOR = 2      # white gap between the border and the payload
CELLS = 8          # payload grid is CELLS x CELLS
CELL = (UNITS - 2 * (QUIET + BORDER + SEPARATOR)) // CELLS   # 9 units = 18 mm at 20 cm
BORDER0 = QUIET                                      # first black border unit
BORDER1 = QUIET + BORDER                             # one past the last
CONTENT0 = BORDER1 + SEPARATOR                       # first payload unit
CONTENT1 = CONTENT0 + CELLS * CELL                   # one past the last

DEFAULT_SEED = 0x67686F73746D6170   # "ghostmap" in ASCII
DEFAULT_SIZE = 2000                 # pixels per side
PHYSICAL_WIDTH_M = 0.20             # what the app passes as ARReferenceImage.physicalWidth

assert CONTENT1 + SEPARATOR + BORDER + QUIET == UNITS, "layout does not fill the square"


# --- Deterministic PRNG ------------------------------------------------------

MASK64 = (1 << 64) - 1


class Xorshift64Star:
    """xorshift64* — 3 shifts and a multiply, identical on every platform."""

    def __init__(self, seed: int) -> None:
        self.state = (seed & MASK64) or 0x9E3779B97F4A7C15

    def next_u64(self) -> int:
        x = self.state
        x ^= (x << 13) & MASK64
        x ^= x >> 7
        x ^= (x << 17) & MASK64
        self.state = x
        return (x * 0x2545F4914F6CDD1D) & MASK64

    def bit(self) -> int:
        # Take a high bit: the low bits of a xorshift word are the weakest.
        return (self.next_u64() >> 33) & 1


# --- Bit grid ----------------------------------------------------------------

def rotate90(grid: list[list[int]]) -> list[list[int]]:
    n = len(grid)
    return [[grid[n - 1 - c][r] for c in range(n)] for r in range(n)]


def is_rotationally_unique(grid: list[list[int]]) -> bool:
    r = grid
    for _ in range(3):
        r = rotate90(r)
        if r == grid:
            return False
    return True


def is_well_spread(grid: list[list[int]]) -> bool:
    """Every row and column carries at least two cells of each colour.

    ARKit rejects reference images whose features clump into a few areas; this
    cheap constraint keeps corners distributed over the whole square.
    """
    n = len(grid)
    for i in range(n):
        row = grid[i]
        col = [grid[r][i] for r in range(n)]
        for line in (row, col):
            black = sum(line)
            if black < 2 or black > n - 2:
                return False
    return True


def has_no_flat_block(grid: list[list[int]], window: int = 3) -> bool:
    """No `window` x `window` block is a single colour.

    Big uniform areas carry no corners, and ARKit grades a reference image by how
    evenly detectable features cover it.
    """
    n = len(grid)
    for r in range(n - window + 1):
        for c in range(n - window + 1):
            block = [grid[r + dr][c + dc] for dr in range(window) for dc in range(window)]
            if all(block) or not any(block):
                return False
    return True


def make_grid(seed: int) -> list[list[int]]:
    """The fixed payload: orientation corner + seeded pseudo-random interior."""
    rng = Xorshift64Star(seed)
    for _ in range(10_000):
        grid = [[0] * CELLS for _ in range(CELLS)]
        # Orientation corner: top-left 2x2 solid black, the other three white.
        # Their asymmetry alone already breaks every rotation.
        fixed = set()
        for dr in range(2):
            for dc in range(2):
                grid[dr][dc] = 1
                fixed.add((dr, dc))
                for r, c in ((dr, CELLS - 1 - dc), (CELLS - 1 - dr, dc), (CELLS - 1 - dr, CELLS - 1 - dc)):
                    grid[r][c] = 0
                    fixed.add((r, c))
        free = [(r, c) for r in range(CELLS) for c in range(CELLS) if (r, c) not in fixed]
        for r, c in free:
            grid[r][c] = rng.bit()
        black = sum(sum(row) for row in grid)
        total = CELLS * CELLS
        if not (0.40 * total <= black <= 0.60 * total):
            continue
        if not is_rotationally_unique(grid):
            continue
        if not is_well_spread(grid):
            continue
        if not has_no_flat_block(grid):
            continue
        return grid
    raise RuntimeError(f"no acceptable grid for seed {seed}")


def grid_text(grid: list[list[int]]) -> str:
    return "\n".join("".join("#" if v else "." for v in row) for row in grid)


# --- Rasterisation -----------------------------------------------------------

def unit_row(v: int, grid: list[list[int]]) -> list[int]:
    """Colours (1 = black) of the 100 units in unit-row `v`."""
    if v < BORDER0 or v >= UNITS - BORDER0:
        return [0] * UNITS                              # quiet zone
    if v < BORDER1 or v >= UNITS - BORDER1:
        return [0] * BORDER0 + [1] * (UNITS - 2 * BORDER0) + [0] * BORDER0   # border
    edge = [0] * BORDER0 + [1] * BORDER + [0] * SEPARATOR
    if v < CONTENT0 or v >= CONTENT1:
        return edge + [0] * (CELLS * CELL) + edge[::-1]  # white separator band
    row = grid[(v - CONTENT0) // CELL]
    return edge + [row[(u - CONTENT0) // CELL] for u in range(CONTENT0, CONTENT1)] + edge[::-1]


def raster(size: int, grid: list[list[int]]) -> bytes:
    """Raw PNG scanlines: filter byte 0 + 8-bit RGB samples, `size` rows."""
    if size % UNITS != 0:
        raise ValueError(f"size must be a multiple of {UNITS}, got {size}")
    scale = size // UNITS
    black = b"\x00" * (3 * scale)
    white = b"\xff" * (3 * scale)
    out = bytearray()
    for v in range(UNITS):
        line = b"\x00" + b"".join(black if c else white for c in unit_row(v, grid))
        out += line * scale
    return bytes(out)


# --- PNG ---------------------------------------------------------------------

def png_chunk(kind: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + kind + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF))


def png_bytes(size: int, compressed: bytes, seed: int) -> bytes:
    px_per_metre = int(round(size / PHYSICAL_WIDTH_M))
    text = b"Comment\x00" + (
        f"Ghostmap origin marker; print at 100 % so the square measures "
        f"{PHYSICAL_WIDTH_M * 100:.0f} cm; seed 0x{seed:X}"
    ).encode("latin-1")
    return b"".join([
        b"\x89PNG\r\n\x1a\n",
        png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)),
        png_chunk(b"pHYs", struct.pack(">IIB", px_per_metre, px_per_metre, 1)),
        png_chunk(b"tEXt", text),
        png_chunk(b"IDAT", compressed),
        png_chunk(b"IEND", b""),
    ])


# --- PDF ---------------------------------------------------------------------

PT_PER_CM = 72.0 / 2.54
A4 = (595.2756, 841.8898)


def pdf_escape(s: str) -> bytes:
    return s.replace("\\", r"\\").replace("(", r"\(").replace(")", r"\)").encode("latin-1")


def pdf_bytes(size: int, compressed: bytes, seed: int) -> bytes:
    """A4 page with the marker at exactly 20 cm and a measuring bar under it.

    The image stream is the *same* zlib data as the PNG's IDAT: PDF's PNG
    predictor (`/Predictor 15`) consumes the per-row filter bytes, so no second
    compression pass is needed.
    """
    side = PHYSICAL_WIDTH_M * 100 * PT_PER_CM      # 566.93 pt
    x0 = (A4[0] - side) / 2
    y0 = A4[1] - side - 42                          # 42 pt of head room
    bar = y0 - 26
    caption = [
        (bar - 26, 11, "Ghostmap origin marker"),
        (bar - 42, 9, f"Print at 100 % (no scaling, no fit-to-page), then check the bar above measures "
                      f"{PHYSICAL_WIDTH_M * 100:.0f}.0 cm."),
        (bar - 55, 9, "Mount it flat and unfolded; matte paper tracks better than glossy. "
                      "Set the same width in Settings if you print it larger or smaller."),
        (bar - 68, 9, f"Generated by scripts/make-marker.py, seed 0x{seed:X}, {size} x {size} px."),
    ]

    ops = [f"q {side:.4f} 0 0 {side:.4f} {x0:.4f} {y0:.4f} cm /Im0 Do Q",
           "0.75 w 0 G",
           f"{x0:.4f} {bar:.4f} m {x0 + side:.4f} {bar:.4f} l S",
           f"{x0:.4f} {bar - 6:.4f} m {x0:.4f} {bar + 6:.4f} l S",
           f"{x0 + side:.4f} {bar - 6:.4f} m {x0 + side:.4f} {bar + 6:.4f} l S"]
    for y, pts, line in caption:
        ops.append(f"BT /F1 {pts} Tf 0 g {x0:.4f} {y:.4f} Td ({pdf_escape(line).decode('latin-1')}) Tj ET")
    content = zlib.compress("\n".join(ops).encode("latin-1"), 9)

    objects: list[bytes] = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        (f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {A4[0]:.4f} {A4[1]:.4f}] "
         f"/Resources << /XObject << /Im0 5 0 R >> /Font << /F1 6 0 R >> >> /Contents 4 0 R >>").encode("latin-1"),
        (b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(content)) + content + b"\nendstream",
        (f"<< /Type /XObject /Subtype /Image /Width {size} /Height {size} /ColorSpace /DeviceRGB "
         f"/BitsPerComponent 8 /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors 3 "
         f"/BitsPerComponent 8 /Columns {size} >> /Length {len(compressed)} >>\nstream\n"
         ).encode("latin-1") + compressed + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    ]

    out = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n" % (len(objects) + 1)
    out += b"0000000000 65535 f \n"
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += (b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n"
            % (len(objects) + 1, xref))
    return bytes(out)


# --- Driver ------------------------------------------------------------------

def write_if_changed(path: Path, data: bytes, check: bool) -> bool:
    """Returns True when `path` already holds `data`."""
    same = path.exists() and path.read_bytes() == data
    if check:
        if not same:
            print(f"OUT OF DATE: {path}", file=sys.stderr)
        return same
    if not same:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"wrote {path} ({len(data):,} bytes)")
    else:
        print(f"unchanged {path} ({len(data):,} bytes)")
    return same


def main(argv: list[str]) -> int:
    root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description="Generate the Ghostmap origin marker.")
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=DEFAULT_SEED)
    ap.add_argument("--size", type=int, default=DEFAULT_SIZE, help=f"pixels per side, multiple of {UNITS}")
    ap.add_argument("--png", type=Path, default=root / "App" / "Marker" / "ghostmap-marker.png")
    ap.add_argument("--pdf", type=Path, default=root / "docs" / "ghostmap-marker.pdf")
    ap.add_argument("--no-pdf", action="store_true", help="only write the PNG")
    ap.add_argument("--check", action="store_true", help="compare with the files on disk instead of writing")
    args = ap.parse_args(argv)

    grid = make_grid(args.seed)
    print(grid_text(grid))
    compressed = zlib.compress(raster(args.size, grid), 9)

    ok = write_if_changed(args.png, png_bytes(args.size, compressed, args.seed), args.check)
    if not args.no_pdf:
        ok &= write_if_changed(args.pdf, pdf_bytes(args.size, compressed, args.seed), args.check)
    return 0 if ok or not args.check else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
