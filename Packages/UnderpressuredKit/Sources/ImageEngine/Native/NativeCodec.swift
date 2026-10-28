import UnderpressuredApplication
import Foundation
import os
import UnderpressuredCore

/// Uses ImageIO transforms and native encoders selected by `EncodePath`.
/// Falls back to ImageIO only when it preserves the selected fidelity contract.
/// `CodecExecutor` keeps codec calls off the main actor and cooperative threads.
/// Calls finish before cancellation takes effect. The Queue discards cancelled results.
public struct NativeCodec: ImageCodec {
    public typealias Image = DecodedImage
    typealias Encoder = @Sendable (EncodePath, DecodedImage, EncodePlan) throws(CodecError) -> EncodedImage

    static let logger = Logger(subsystem: "app.underpressured.Underpressured", category: "codec")

    private let native: Encoder

    public init() {
        self.init(native: NativeCodec.encode)
    }

    /// Tests inject a failing encoder to exercise the fallback.
    init(native: @escaping Encoder) {
        self.native = native
    }

    public func inspect(_ data: Data) async throws(CodecError) -> ImageInfo {
        try await CodecExecutor.run { () throws(CodecError) in try Decode.inspect(data) }
    }

    public func decode(_ data: Data) async throws(CodecError) -> DecodedImage {
        try await CodecExecutor.run { () throws(CodecError) in try Decode.decode(data) }
    }

    public func transform(_ image: DecodedImage, _ plan: TransformPlan) async throws(CodecError) -> DecodedImage {
        try await CodecExecutor.run { () throws(CodecError) in try ImageIOCodec.transform(image, plan) }
    }

    public func encode(_ image: DecodedImage, _ plan: EncodePlan) async throws(CodecError) -> EncodedImage {
        let path = EncodePath.select(plan, image)
        let native = self.native
        do {
            return try await CodecExecutor.run { () throws(CodecError) in try native(path, image, plan) }
        } catch {
            Self.logger.error(
                "native \(String(describing: path), privacy: .public) failed: \(String(describing: error), privacy: .public)")
            switch path.fallback {
            case .unavailable:
                throw .losslessEncoderUnavailable
            case .imageIO(let notes):
                var output = try await CodecExecutor.run { () throws(CodecError) in try Encode.encode(image, plan) }
                output.notes += notes
                return output
            }
        }
    }

    /// The real native encoders, one per §7.4 cell.
    static func encode(_ path: EncodePath, _ image: DecodedImage, _ plan: EncodePlan) throws(CodecError) -> EncodedImage {
        switch path {
        case .jpegLossy: try JPEGEncode.lossy(image, plan)
        case .jpegVisuallyLossless: try JPEGEncode.visuallyLossless(image, plan)
        case .jpegLosslessRewrite: try LosslessJPEG.rewrite(image, keepMetadata: plan.keepMetadata)
        case .pngLossless: try PNGLossless.encode(image, plan)
        case .pngPalette: try PNGPalette.encode(image, plan)
        }
    }
}
