import ARKit
import Foundation
import UIKit

/// Why the printed marker could not be turned into an `ARReferenceImage`.
enum MarkerReferenceError: Error, Equatable, CustomStringConvertible {
    /// `Marker/ghostmap-marker.png` is missing from the app bundle (check project.yml).
    case resourceMissing(name: String)
    /// The file is there but is not a decodable image.
    case notAnImage(name: String)
    /// `physicalWidth` outside the range ARKit can track.
    case invalidPhysicalWidth(Double)

    var description: String {
        switch self {
        case .resourceMissing(let name):
            return "marker image \(name).png is not in the app bundle"
        case .notAnImage(let name):
            return "marker image \(name).png could not be decoded"
        case .invalidPhysicalWidth(let width):
            return "marker width \(width) m is outside \(MarkerReference.minimumWidth)–\(MarkerReference.maximumWidth) m"
        }
    }
}

/// The printed origin marker, loaded from the app bundle as an `ARReferenceImage`.
///
/// The PNG is generated (and regenerated) by `scripts/make-marker.py`; it is 2000 × 2000 px for a
/// printed square of `defaultWidth` metres. No asset catalog is involved: the file is copied into
/// the bundle by project.yml and read with `Bundle.main.url(forResource:withExtension:)`, because
/// `ARReferenceImage` needs a `CGImage` and not a catalog entry.
enum MarkerReference {
    /// Resource name and the `ARReferenceImage.name` the session controller matches anchors against.
    static let name = "ghostmap-marker"
    static let subdirectory = "Marker"
    /// The printed size the PDF and PNG are laid out for.
    static let defaultWidth: Double = 0.20
    /// Guard rails for the user-entered width; ARKit tracks neither postage stamps nor billboards well.
    static let minimumWidth: Double = 0.05
    static let maximumWidth: Double = 2.0

    /// Clamps a user-entered width to the trackable range.
    static func clampWidth(_ width: Double) -> Double {
        min(maximumWidth, max(minimumWidth, width))
    }

    /// The bundled marker as an `ARReferenceImage` of `physicalWidth` metres.
    ///
    /// - Throws: ``MarkerReferenceError`` when the resource is missing, undecodable or the width is
    ///   out of range. Callers keep running without image detection rather than failing the session.
    static func referenceImage(physicalWidth: Double = defaultWidth) throws(MarkerReferenceError) -> ARReferenceImage {
        guard physicalWidth >= minimumWidth, physicalWidth <= maximumWidth else {
            throw .invalidPhysicalWidth(physicalWidth)
        }
        // Look in the Marker/ subdirectory first (how project.yml copies it) and fall back to the
        // bundle root, which is where a flattened resource build would put it.
        let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: name, withExtension: "png")
        guard let url else { throw .resourceMissing(name: name) }
        guard let image = UIImage(contentsOfFile: url.path), let cgImage = image.cgImage else {
            throw .notAnImage(name: name)
        }
        let reference = ARReferenceImage(cgImage, orientation: .up, physicalWidth: CGFloat(physicalWidth))
        reference.name = name
        return reference
    }
}
