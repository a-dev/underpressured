/// The Output Format picker (spec §5). Not part of a Preset.
public enum OutputFormat: Sendable, Hashable, CaseIterable {
    case original
    case jpeg
    case png
}

/// An accepted source image format (spec §7.2), found by content type.
public enum ImageFormat: Sendable, Hashable, CaseIterable {
    case jpeg
    case png
    case heic
    case webp
    case tiff
    case avif
    case jpegXL

    /// The name used in user-facing text, e.g. "Can't write HEIC yet…".
    public var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .avif: "AVIF"
        case .jpegXL: "JPEG XL"
        }
    }
}

/// A format the app can write in v0: the result of resolving an Output Format (§5).
public enum WritableFormat: Sendable, Hashable, CaseIterable {
    case jpeg
    case png

    public var imageFormat: ImageFormat {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        }
    }
}
