import UnderpressuredApplication
import UnderpressuredCore
import UniformTypeIdentifiers

public enum FileContentClassifier {
    /// How a content type is handled.
    static let avif = UTType("public.avif") ?? UTType(importedAs: "public.avif")
    static let jpegXL = UTType("public.jxl") ?? UTType(importedAs: "public.jxl")

    public static func classify(_ type: UTType?) -> FileContentType {
        guard let type else { return .notAnImage }
        let accepted: [(UTType, ImageFormat)] = [
            (.jpeg, .jpeg), (.png, .png), (.heic, .heic), (.heif, .heic), (.webP, .webp),
            (.tiff, .tiff), (avif, .avif), (jpegXL, .jpegXL),
        ]
        if let match = accepted.first(where: { type.conforms(to: $0.0) }) {
            return .accepted(match.1)
        }
        if type.conforms(to: .gif) { return .unsupported(.gif) }
        if type.conforms(to: .rawImage) { return .unsupported(.raw) }
        if type.conforms(to: .image) { return .unsupported(.otherType) }
        return .notAnImage
    }

}
