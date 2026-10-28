import UnderpressuredApplication
import Foundation
internal import UpCodecs

/// Lossless PNG optimization (oxipng). Ancillary chunks, metadata included, are kept as given.
public enum Oxipng {
    /// - Parameter level: 0...6.
    public static func optimize(_ png: Data, level: UInt8) throws(OxipngError) -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status = png.withUnsafeBytes { buf in
            up_png_optimize(
                buf.baseAddress?.assumingMemoryBound(to: UInt8.self), buf.count,
                level, &out, &outLen)
        }
        defer { up_buffer_free(out, outLen) }
        switch status {
        case UP_OK:
            guard let out else { throw .encodeFailed }
            return Data(bytes: out, count: outLen)
        case UP_INVALID_ARGUMENT: throw .invalidArgument
        case UP_DECODE_FAILED: throw .decodeFailed
        case UP_ENCODE_FAILED: throw .encodeFailed
        case UP_PANIC: throw .panic
        default: throw .unknown(Int(status.rawValue))
        }
    }
}

public enum OxipngError: Error, Sendable, Equatable {
    case invalidArgument
    case decodeFailed
    case encodeFailed
    case panic
    case unknown(Int)
}
