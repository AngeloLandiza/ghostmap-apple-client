import SwiftUI

/// The three things a party needs from the printed marker, shown before the first party starts and
/// under the marker toggle in Settings. Kept short: the status strip on the capture screen tells the
/// user when the phone has actually locked on.
struct MarkerGuide: View {
    private var centimetres: Int { Int((MarkerReference.defaultWidth * 100).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            step(1, "Print the sheet at 100 % (no “fit to page”). The outer black square must measure \(centimetres) cm; if yours differs, set the size in Settings.")
            step(2, "Tape it flat on a wall or table where every phone in the party can see it.")
            step(3, "Point the phone at it until the status strip reads “Marker: aligned”, then scan. Every phone that sees the same sheet shares one coordinate frame.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).").monospacedDigit()
            Text(text)
        }
    }
}

/// Opens the system share sheet with the bundled marker PDF so it can be AirPrinted, AirDropped to
/// a Mac, or saved to Files. The PDF is copied into the bundle next to the PNG that ARKit tracks.
struct MarkerShareButton: View {
    private var centimetres: Int { Int((MarkerReference.defaultWidth * 100).rounded()) }

    var body: some View {
        if let url = MarkerReference.printableURL {
            ShareLink(item: url, preview: SharePreview("Ghostmap marker (\(centimetres) cm)")) {
                Label("Get the marker (PDF)", systemImage: "printer")
            }
            .accessibilityHint("Opens the share sheet to print or save the marker")
        } else {
            Label("Marker PDF is missing from this build", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        }
    }
}
