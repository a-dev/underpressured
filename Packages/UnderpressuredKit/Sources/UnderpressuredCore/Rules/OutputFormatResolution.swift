/// What an Output Format means for one source format (spec §5).
public enum OutputFormatResolution: Sendable, Hashable {
    case write(WritableFormat)
    case skip(SkipReason)
}

extension OutputFormat {
    /// Resolves this Output Format against a source format (spec §5 table).
    public func resolve(for source: ImageFormat) -> OutputFormatResolution {
        switch self {
        case .jpeg: .write(.jpeg)
        case .png: .write(.png)
        case .original:
            switch source {
            case .jpeg: .write(.jpeg)
            case .png: .write(.png)
            case .heic, .webp, .tiff, .avif, .jpegXL: .skip(.cantWriteYet(source))
            }
        }
    }
}

extension WritableFormat {
    /// JPEG has no alpha, so transparency is flattened onto white before encoding (§5, §7.3).
    public var flattensTransparencyOntoWhite: Bool { self == .jpeg }

    /// The extension given to converted files (§5).
    public var conversionExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .png: "png"
        }
    }
}

/// Preserve the source name for unchanged formats. For conversions, replace the extension with `.jpg` or `.png`.
public func outputFileName(
    sourceFileName: String,
    source: ImageFormat,
    resolved: WritableFormat
) -> String {
    if source == resolved.imageFormat { return sourceFileName }
    var base = sourceFileName
    // A leading dot is part of the name, not an extension separator.
    if let dot = base.lastIndex(of: "."), dot != base.startIndex {
        base = String(base[..<dot])
    }
    return base + "." + resolved.conversionExtension
}
