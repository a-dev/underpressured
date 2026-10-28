import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// Copies JPEG DCT coefficients without decoding. Preserves orientation because the pixels do not rotate.
enum LosslessJPEG {
    static func rewrite(_ image: DecodedImage, keepMetadata: Bool) throws(CodecError) -> EncodedImage {
        guard let source = image.sourceData else { throw .encodeFailed("lossless JPEG: no source bytes") }
        let orientation = Decode.orientation(of: image.metadata.properties)
        let data: Data
        do {
            data = try Jpegli.losslessRewrite(source, keepMetadata: keepMetadata, orientation: orientation)
        } catch {
            throw .encodeFailed("lossless JPEG rewrite: \(error)")
        }
        // Only the primary image is written, so a gain map (MPF secondary image) is gone.
        let notes: [Note] = image.facts.hasGainMap ? [.hdrRemoved] : []
        return EncodedImage(
            data: data, format: .jpeg, pixelWidth: image.pixels.width, pixelHeight: image.pixels.height,
            notes: image.notes + notes)
    }
}
