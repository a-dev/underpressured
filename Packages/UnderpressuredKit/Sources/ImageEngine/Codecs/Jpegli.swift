import UnderpressuredApplication
import Foundation
internal import UpJpegli

/// Thin wrapper over the jpegli C shim. No policy: every parameter is explicit.
public enum Jpegli {
    public enum Components: Int, Sendable {
        case gray = 1
        case rgb = 3
    }

    /// Internal boundary used to observe the distance request while retaining the real encoder.
    typealias DistanceEncoder = (
        UnsafeRawBufferPointer, Int, Int, Int, Components, Float, Bool, Data?
    ) throws(JpegliError) -> Data

    /// Encodes 8-bit interleaved pixels to a JPEG at a libjpeg quality.
    /// - Parameters:
    ///   - pixels: `bytesPerRow * (height - 1) + width * components.rawValue` readable bytes.
    ///   - quality: libjpeg 0...100 scale, passed through unchanged.
    public static func encode(
        pixels: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        components: Components,
        quality: Int,
        progressive: Bool,
        iccProfile: Data?
    ) throws(JpegliError) -> Data {
        try encode(pixels, width, height, bytesPerRow, components, iccProfile) { base, icc, iccLen, out, outLen in
            upj_encode(
                base, UInt32(width), UInt32(height), bytesPerRow, UInt32(components.rawValue),
                Int32(clamping: quality), progressive ? 1 : 0, icc, iccLen, out, outLen)
        }
    }

    /// Encodes 8-bit interleaved pixels to a JPEG at a Butteraugli distance (1.0 = visually lossless).
    public static func encode(
        pixels: UnsafeRawBufferPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        components: Components,
        distance: Float,
        progressive: Bool,
        iccProfile: Data?
    ) throws(JpegliError) -> Data {
        try encode(pixels, width, height, bytesPerRow, components, iccProfile) { base, icc, iccLen, out, outLen in
            upj_encode_distance(
                base, UInt32(width), UInt32(height), bytesPerRow, UInt32(components.rawValue),
                distance, progressive ? 1 : 0, icc, iccLen, out, outLen)
        }
    }

    /// Rewrites DCT coefficients with optimized Huffman tables and progressive scans. Always preserves ICC.
    /// `keepMetadata` preserves EXIF, IPTC, and XMP except gain-map XMP. Otherwise, writes only non-default EXIF orientation.
    public static func losslessRewrite(_ jpeg: Data, keepMetadata: Bool, orientation: Int) throws(JpegliError) -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let status = jpeg.withUnsafeBytes { buf in
            upj_lossless_rewrite(
                buf.baseAddress?.assumingMemoryBound(to: UInt8.self), buf.count, keepMetadata ? 1 : 0,
                UInt32(clamping: orientation), &out, &outLen)
        }
        defer { upj_buffer_free(out) }
        try check(status)
        guard let out else { throw .encodeFailed }
        return Data(bytes: out, count: outLen)
    }

    /// True when both JPEGs hold the same DCT coefficients, quantization tables and sampling.
    public static func coefficientsEqual(_ a: Data, _ b: Data) throws(JpegliError) -> Bool {
        var equal: Int32 = 0
        let status = a.withUnsafeBytes { aBuf in
            b.withUnsafeBytes { bBuf in
                upj_coefficients_equal(
                    aBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), aBuf.count,
                    bBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), bBuf.count, &equal)
            }
        }
        try check(status)
        return equal != 0
    }

    /// SSIMULACRA2 (100 = identical) between two 8-bit sRGB images of the same size, at least 8×8.
    public static func ssimulacra2(
        reference: UnsafeRawBufferPointer, distorted: UnsafeRawBufferPointer,
        width: Int, height: Int, bytesPerRow: Int, components: Components
    ) throws(JpegliError) -> Double {
        let needed = (height - 1) * bytesPerRow + width * components.rawValue
        guard width > 0, height > 0, reference.count >= needed, distorted.count >= needed,
              let ref = reference.baseAddress, let dist = distorted.baseAddress
        else { throw .invalidArgument }
        var score = 0.0
        try check(upj_ssimulacra2(
            ref.assumingMemoryBound(to: UInt8.self), bytesPerRow,
            dist.assumingMemoryBound(to: UInt8.self), bytesPerRow,
            UInt32(width), UInt32(height), UInt32(components.rawValue), &score))
        return score
    }

    private typealias EncodeCall = (
        UnsafePointer<UInt8>, UnsafePointer<UInt8>?, Int,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, UnsafeMutablePointer<Int>
    ) -> UpjStatus

    private static func encode(
        _ pixels: UnsafeRawBufferPointer, _ width: Int, _ height: Int, _ bytesPerRow: Int,
        _ components: Components, _ iccProfile: Data?, _ call: EncodeCall
    ) throws(JpegliError) -> Data {
        let rowBytes = width.multipliedReportingOverflow(by: components.rawValue)
        guard width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max),
              !rowBytes.overflow, bytesPerRow >= rowBytes.partialValue,
              let base = pixels.baseAddress,
              pixels.count >= (height - 1) * bytesPerRow + rowBytes.partialValue
        else { throw .invalidArgument }

        var out: UnsafeMutablePointer<UInt8>?
        var outLen = 0
        let icc = iccProfile ?? Data()
        let status = icc.withUnsafeBytes { iccBuf in
            call(
                base.assumingMemoryBound(to: UInt8.self),
                iccBuf.baseAddress?.assumingMemoryBound(to: UInt8.self), iccBuf.count, &out, &outLen)
        }
        defer { upj_buffer_free(out) }
        try check(status)
        guard let out else { throw .encodeFailed }
        return Data(bytes: out, count: outLen)
    }

    private static func check(_ status: UpjStatus) throws(JpegliError) {
        switch status {
        case UPJ_OK: return
        case UPJ_INVALID_ARGUMENT: throw .invalidArgument
        case UPJ_ENCODE_FAILED: throw .encodeFailed
        case UPJ_DECODE_FAILED: throw .decodeFailed
        default: throw .unknown(Int(status.rawValue))
        }
    }
}

public enum JpegliError: Error, Sendable, Equatable {
    case invalidArgument
    case encodeFailed
    case decodeFailed
    case unknown(Int)
}
