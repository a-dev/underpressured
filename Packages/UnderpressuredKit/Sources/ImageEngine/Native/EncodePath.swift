import UnderpressuredApplication
import UnderpressuredCore

/// One cell of the §7.4 encode-path table.
enum EncodePath: Sendable, Hashable, CaseIterable {
    /// Lossy jpegli at Quality, progressive.
    case jpegLossy
    /// Same DCT coefficients, optimized Huffman, progressive (0.12).
    case jpegLosslessRewrite
    /// jpegli at Butteraugli distance 1.0, note "re-encoded at visually lossless quality".
    case jpegVisuallyLossless
    /// quantizr palette with the SSIMULACRA2-floor search (0.13), else lossless with "kept full color".
    case pngPalette
    /// oxipng `-o 2`.
    case pngLossless

    enum Fallback {
        case imageIO(notes: [Note])
        case unavailable
    }

    /// ImageIO has no coefficient rewrite or validated Butteraugli-distance encoder.
    /// Full-color PNG preserves at least the fidelity promised by palette output.
    var fallback: Fallback {
        switch self {
        case .jpegLossy, .pngLossless: .imageIO(notes: [])
        case .pngPalette: .imageIO(notes: [.keptFullColor])
        case .jpegLosslessRewrite, .jpegVisuallyLossless: .unavailable
        }
    }

    static func select(_ plan: EncodePlan, _ image: DecodedImage) -> EncodePath {
        switch plan.format {
        case .jpeg:
            guard plan.lossless else { return .jpegLossy }
            let canRewrite = image.facts.format == .jpeg && !image.pixelsTransformed && image.sourceData != nil
            return canRewrite ? .jpegLosslessRewrite : .jpegVisuallyLossless
        case .png:
            return plan.lossless || plan.quality.rawValue >= PNGPalette.losslessQuality ? .pngLossless : .pngPalette
        }
    }
}
