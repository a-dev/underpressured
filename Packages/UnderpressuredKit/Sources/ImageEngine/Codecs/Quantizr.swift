import UnderpressuredApplication
import Foundation
internal import UpCodecs

/// Palette quantization (quantizr) to an indexed PNG, then oxipng.
public enum Quantizr {
    /// - Parameters:
    ///   - rgba: non-premultiplied RGBA8; `bytesPerRow * (height - 1) + width * 4` readable bytes.
    ///   - maxColors: 2...256.
    ///   - dither: 0...1.
    ///   - oxipngLevel: 0...6.
    public static func quantize(
        rgba: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        maxColors: Int,
        dither: Float,
        oxipngLevel: UInt8
    ) throws(QuantizrError) -> Data {
        let rowBytes = width.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              !rowBytes.overflow, bytesPerRow >= rowBytes.partialValue,
              let base = rgba.baseAddress,
              rgba.count >= (height - 1) * bytesPerRow + rowBytes.partialValue
        else { throw .invalidArgument }

        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status = up_png_quantize(
            base.assumingMemoryBound(to: UInt8.self),
            UInt32(width), UInt32(height), bytesPerRow,
            Int32(clamping: maxColors), dither, oxipngLevel, &out, &outLen)
        defer { up_buffer_free(out, outLen) }
        switch status {
        case UP_OK:
            guard let out else { throw .encodeFailed }
            return Data(bytes: out, count: outLen)
        case UP_INVALID_ARGUMENT: throw .invalidArgument
        case UP_DECODE_FAILED: throw .decodeFailed
        case UP_ENCODE_FAILED: throw .encodeFailed
        case UP_QUANTIZE_FAILED: throw .quantizeFailed
        case UP_PANIC: throw .panic
        default: throw .unknown(Int(status.rawValue))
        }
    }
}

public enum QuantizrError: Error, Sendable, Equatable {
    case invalidArgument
    case decodeFailed
    case encodeFailed
    case quantizeFailed
    case panic
    case unknown(Int)
}
