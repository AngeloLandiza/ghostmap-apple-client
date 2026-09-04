#!/usr/bin/env bash
# RoomMapper build / test / run pipeline.
#
#   scripts/rm.sh setup        install XcodeGen and the Metal toolchain if missing
#   scripts/rm.sh gen          regenerate RoomMapper.xcodeproj from project.yml
#   scripts/rm.sh marker       regenerate the printable origin marker (PNG + PDF)
#   scripts/rm.sh test         run the MapCore unit tests on the Mac
#   scripts/rm.sh build [debug|release]   build for the connected iPhone (signed)
#   scripts/rm.sh install      install the last build on the iPhone
#   scripts/rm.sh launch       launch it with the console attached (Ctrl-C detaches)
#   scripts/rm.sh run          build + install + launch
#   scripts/rm.sh all          test + run
#   scripts/rm.sh pull-maps    copy every map (manifest, keyframes.bin, cloud.ply, session.log) from the phone
#   scripts/rm.sh devices      show the connected devices and the ids in use
#   scripts/rm.sh clean        delete build products
#
# Environment overrides: RM_DEVICE (CoreDevice id for devicectl), RM_UDID (hardware UDID for xcodebuild),
# DEVELOPER_DIR (defaults to Xcode-beta if xcode-select points at the Command Line Tools),
# RM_DD (derived data dir, default /tmp/roommapper-dd — must be outside iCloud-synced folders).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="tech.alandiza.roommapper"
SCHEME="RoomMapper"
DD="${RM_DD:-/tmp/roommapper-dd}"
SCRATCH="${RM_SCRATCH:-/tmp/mapcore-build}"
CONFIG="${RM_CONFIG:-Debug}"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

pick_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then return; fi
  local current; current="$(xcode-select -p 2>/dev/null || true)"
  if [[ "$current" == *CommandLineTools* || -z "$current" ]]; then
    for x in /Applications/Xcode.app /Applications/Xcode-beta.app; do
      if [[ -d "$x" ]]; then export DEVELOPER_DIR="$x/Contents/Developer"; return; fi
    done
    red "No Xcode.app found"; exit 1
  fi
}

detect_device() {
  if [[ -n "${RM_DEVICE:-}" && -n "${RM_UDID:-}" ]]; then return; fi
  local json="/tmp/rm-devices.json"
  xcrun devicectl list devices -j "$json" >/dev/null 2>&1 || { red "devicectl failed; is Xcode installed?"; exit 1; }
  local ids
  ids="$(python3 - "$json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for dev in d.get("result", {}).get("devices", []):
    hw = dev.get("hardwareProperties", {})
    conn = dev.get("connectionProperties", {})
    if hw.get("platform") != "iOS" or hw.get("reality") == "virtual":
        continue
    if conn.get("tunnelState") not in ("connected", "available") and "connected" not in str(conn):
        continue
    print(dev["identifier"], hw.get("udid", ""), dev.get("deviceProperties", {}).get("name", "?").replace(" ", "_"))
    break
PY
)"
  if [[ -z "$ids" ]]; then red "No connected iPhone found (unlock it, trust this Mac, enable Developer Mode)"; exit 1; fi
  RM_DEVICE="${RM_DEVICE:-$(echo "$ids" | awk '{print $1}')}"
  RM_UDID="${RM_UDID:-$(echo "$ids" | awk '{print $2}')}"
  RM_DEVICE_NAME="$(echo "$ids" | awk '{print $3}')"
  export RM_DEVICE RM_UDID
}

cmd_setup() {
  pick_developer_dir
  command -v xcodegen >/dev/null || { bold "Installing XcodeGen"; HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1 brew install xcodegen; }
  if ! xcrun -f metal >/dev/null 2>&1; then bold "Downloading the Metal toolchain"; xcodebuild -downloadComponent MetalToolchain; fi
  green "setup ok (DEVELOPER_DIR=$DEVELOPER_DIR)"
}

cmd_gen() {
  pick_developer_dir
  (cd "$ROOT" && xcodegen generate --quiet)
  green "generated $ROOT/RoomMapper.xcodeproj"
}

cmd_test() {
  pick_developer_dir
  bold "MapCore unit tests"
  (cd "$ROOT/Packages/MapCore" && xcrun swift test --scratch-path "$SCRATCH" 2>&1 | grep -E "error:|warning:|failed|Executed [0-9]+ tests" | tail -6)
  (cd "$ROOT/Packages/MapCore" && xcrun swift test --scratch-path "$SCRATCH" >/dev/null 2>&1) && green "tests passed" || { red "tests FAILED"; exit 1; }
}

cmd_build() {
  pick_developer_dir; detect_device
  case "${1:-debug}" in release|Release) CONFIG=Release;; *) CONFIG=Debug;; esac
  [[ -d "$ROOT/RoomMapper.xcodeproj" ]] || cmd_gen
  find "$ROOT/App" "$ROOT/Packages" -name "* 2.*" -delete 2>/dev/null || true
  bold "Building $CONFIG for $RM_DEVICE_NAME ($RM_UDID)"
  local log="/tmp/rm-build.log"
  if xcodebuild -project "$ROOT/RoomMapper.xcodeproj" -scheme "$SCHEME" -destination "platform=iOS,id=$RM_UDID" \
       -configuration "$CONFIG" -allowProvisioningUpdates -derivedDataPath "$DD" build >"$log" 2>&1; then
    green "build ok → $(app_path)"
  else
    grep -E "error:|error " "$log" | grep -v "Shaders.dia" | sort -u | head -30
    red "build FAILED (full log: $log)"; exit 1
  fi
}

app_path() { echo "$DD/Build/Products/$CONFIG-iphoneos/RoomMapper.app"; }

cmd_install() {
  pick_developer_dir; detect_device
  local app; app="$(app_path)"
  [[ -d "$app" ]] || { red "no build at $app — run: scripts/rm.sh build"; exit 1; }
  bold "Installing on $RM_DEVICE_NAME"
  xcrun devicectl device install app --device "$RM_DEVICE" "$app" | grep -E "installed|Error|error" || true
  green "installed"
}

cmd_launch() {
  pick_developer_dir; detect_device
  bold "Launching $BUNDLE_ID (Ctrl-C detaches the console; the app keeps running)"
  xcrun devicectl device process launch --device "$RM_DEVICE" --terminate-existing --console "$BUNDLE_ID"
}

cmd_pull_maps() {
  pick_developer_dir; detect_device
  local dest="${1:-$ROOT/maps-export}"
  mkdir -p "$dest"
  bold "Copying Documents/Maps from the phone to $dest"
  xcrun devicectl device copy from --device "$RM_DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
    --source Documents/Maps --destination "$dest"
  green "done: $(find "$dest" -name manifest.json | wc -l | tr -d ' ') map(s)"
}

cmd_marker() {
  python3 "$ROOT/scripts/make-marker.py"
  green "marker: App/Marker/ghostmap-marker.png + docs/ghostmap-marker.pdf (print at 100 %)"
}

cmd_devices() {
  pick_developer_dir
  xcrun devicectl list devices 2>/dev/null | sed -n '1,20p'
  detect_device
  echo "using: name=$RM_DEVICE_NAME coredevice=$RM_DEVICE udid=$RM_UDID DEVELOPER_DIR=$DEVELOPER_DIR"
}

cmd_clean() {
  rm -rf "$DD" "$SCRATCH" "$ROOT/build" "$ROOT/Packages/MapCore/.build"
  green "cleaned"
}

case "${1:-help}" in
  setup) cmd_setup;;
  gen) cmd_gen;;
  marker) cmd_marker;;
  test) cmd_test;;
  build) cmd_build "${2:-debug}";;
  install) cmd_install;;
  launch) cmd_launch;;
  run) cmd_build "${2:-debug}"; cmd_install; cmd_launch;;
  all) cmd_test; cmd_build "${2:-debug}"; cmd_install; cmd_launch;;
  pull-maps) cmd_pull_maps "${2:-}";;
  devices) cmd_devices;;
  clean) cmd_clean;;
  *) sed -n '2,20p' "$0";;
esac
