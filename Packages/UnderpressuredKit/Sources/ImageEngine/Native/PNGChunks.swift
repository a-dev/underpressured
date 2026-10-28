import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// PNG container edits only. Metadata selection and normalization belong to `Metadata`.
enum PNGChunks {
    private static let signature = Data([137, 80, 78, 71, 13, 10, 26, 10])

    /// Attach ancillary chunks from ImageIO's finalized, policy-normalized output without re-encoding
    /// indexed pixels. PNG's safe-to-copy bit excludes layout-dependent bKGD, hIST, sBIT and tRNS.
    /// Color declarations are also transferable: both encodings use the same RGB sample space.
    static func finalizePalette(_ palette: Data, using lossless: Data, colorFrom colorPNG: Data? = nil) throws(CodecError) -> Data {
        let pixels = try chunks(palette)
        let normalized = try chunks(lossless)
        let colorChunks: Set<String> = ["iCCP", "sRGB", "gAMA", "cHRM", "cICP", "mDCV", "cLLI"]
        let colors = try chunks(colorPNG ?? lossless).filter { colorChunks.contains($0.type) }
        let ancillary = normalized.filter {
            let type = Array($0.type.utf8)
            return type[0] & 0x20 != 0 && type[3] & 0x20 != 0 && !colorChunks.contains($0.type)
        }
        var output = signature
        var wroteAncillary = false
        for chunk in pixels {
            // Keep unknown chunks on their original side of IDAT, as required by PNG editing rules.
            if chunk.type == "IDAT", !wroteAncillary {
                for chunk in ancillary where !chunk.afterImageData { output.append(chunk.bytes) }
                wroteAncillary = true
            }
            if chunk.type == "IEND" {
                for chunk in ancillary where chunk.afterImageData { output.append(chunk.bytes) }
            }
            // quantizr owns the indexed pixel stream and its palette-dependent transparency.
            if ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"].contains(chunk.type) { output.append(chunk.bytes) }
            if chunk.type == "IHDR" {
                for chunk in colors { output.append(chunk.bytes) }
            }
        }
        return output
    }

    private struct Chunk {
        let type: String
        let bytes: Data
        let afterImageData: Bool
    }

    /// Inputs are finalized encoder outputs; retain their payloads and CRCs verbatim.
    private static func chunks(_ png: Data) throws(CodecError) -> [Chunk] {
        let bytes = [UInt8](png)
        guard png.starts(with: signature) else { throw .encodeFailed("Invalid PNG signature") }
        var result: [Chunk] = []
        var offset = 8
        var sawImageData = false
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let end = offset + 12 + length
            guard end <= bytes.count else { throw .encodeFailed("Truncated PNG chunk") }
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            result.append(Chunk(type: type, bytes: Data(bytes[offset..<end]), afterImageData: sawImageData))
            if type == "IDAT" { sawImageData = true }
            offset = end
            if type == "IEND" {
                guard offset == bytes.count, result.first?.type == "IHDR", sawImageData else {
                    throw .encodeFailed("Invalid PNG chunk order")
                }
                return result
            }
        }
        throw .encodeFailed("Incomplete PNG")
    }
}
