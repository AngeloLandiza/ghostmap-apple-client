/// Typed errors for every MapCore operation.
public enum MapError: Error, Sendable, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt16)
    case truncatedRecord(offset: Int64)
    case corruptRecord(offset: Int64, reason: String)
    case compressionFailed
    case decompressionFailed(expected: Int, actual: Int)
    case sizeMismatch(expected: Int, actual: Int)
    case mapNotFound(MapID)
    case invalidManifest(String)
    case invalidPLY(String)
    case io(String)
    case cloudFull
}
