import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// ImageIO prepares lossless PNG pixels, color profile, and metadata. oxipng `-o 2` recompresses the result.
enum PNGLossless {
    static let level: UInt8 = 2

    static func encode(_ image: DecodedImage, _ plan: EncodePlan) throws(CodecError) -> EncodedImage {
        let base = try Encode.encode(image, plan)
        return EncodedImage(
            data: try optimize(base.data), format: .png, pixelWidth: base.pixelWidth,
            pixelHeight: base.pixelHeight, notes: base.notes)
    }

    /// Recompresses an already-encoded PNG without changing a pixel.
    static func optimize(_ png: Data) throws(CodecError) -> Data {
        let out: Data
        do {
            out = try Oxipng.optimize(png, level: level)
        } catch {
            throw .encodeFailed("oxipng: \(error)")
        }
        guard out.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) else {
            throw .encodeFailed("oxipng: output is not a PNG")
        }
        return out
    }
}
