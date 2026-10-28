import UnderpressuredCore
import Foundation

/// Codec stages implemented by ImageEngine. Tests can supply a fake.
/// Check cancellation between calls. Never interrupt a call.
public protocol ImageCodec: Sendable {
    /// Decoded pixels plus whatever the engine needs to encode them later. Opaque to Core.
    associatedtype Image: Sendable

    /// Format, pixel size and frame count, read without decoding pixels.
    func inspect(_ data: Data) async throws(CodecError) -> ImageInfo
    func decode(_ data: Data) async throws(CodecError) -> Image
    func transform(_ image: Image, _ plan: TransformPlan) async throws(CodecError) -> Image
    func encode(_ image: Image, _ plan: EncodePlan) async throws(CodecError) -> EncodedImage
}

public struct EncodedImage: Sendable, Hashable {
    public var data: Data
    public var format: WritableFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var notes: [Note]

    public init(data: Data, format: WritableFormat, pixelWidth: Int, pixelHeight: Int, notes: [Note] = []) {
        self.data = data
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.notes = notes
    }
}

public enum CodecError: Error, Sendable, Hashable {
    /// Maps to FailReason.cantRead.
    case unreadable
    /// Maps to FailReason.encodeFailed.
    case encodeFailed(String)
    /// No fallback can preserve the selected lossless JPEG guarantee.
    case losslessEncoderUnavailable
}
