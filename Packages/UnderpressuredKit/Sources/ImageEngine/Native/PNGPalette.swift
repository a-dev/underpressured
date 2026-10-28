import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UnderpressuredCore

/// Uses a quantizr palette only if it meets `ssimFloor(Quality)` and reduces file size.
/// The floor matches jpegli at the same Quality. Otherwise, writes lossless PNG with "kept full color".
enum PNGPalette {
    /// Quality at or above this is lossless PNG: floor 90 is out of palette reach (0.13).
    static let losslessQuality = 98
    static let paletteSizes = [16, 32, 64, 128, 256]
    static let ditherLevels: [Float] = [0, 0.5, 1]

    /// Piecewise linear through the Q1 jpegli medians.
    static func ssimFloor(_ quality: Int) -> Double {
        let points: [(Double, Double)] = [(0, 30), (57, 70), (85, 80), (98, 90), (100, 90)]
        let q = Double(min(max(quality, 0), 100))
        for (a, b) in zip(points, points.dropFirst()) where q <= b.0 {
            return a.1 + (b.1 - a.1) * (q - a.0) / (b.0 - a.0)
        }
        return points.last!.1
    }

    static func encode(_ image: DecodedImage, _ plan: EncodePlan) throws(CodecError) -> EncodedImage {
        var losslessPlan = plan
        losslessPlan.lossless = true
        let lossless = try PNGLossless.encode(image, losslessPlan)
        var keptFullColor = lossless
        keptFullColor.notes.append(.keptFullColor)

        let source = try PixelBuffer.render(image.pixels, layout: .rgba8, sourceProfile: image.facts.iccProfile)
        // SSIMULACRA2 needs at least 8×8; a smaller image can't be checked, so it keeps full color.
        guard source.width >= 8, source.height >= 8 else { return keptFullColor }

        var search = Search(source: source, floor: ssimFloor(plan.quality.rawValue))
        guard let best = try search.run() else { return keptFullColor }
        // Gray and indexed inputs are rendered to sRGB for quantization. Their original PNG
        // color declarations cannot describe that RGB palette; ask ImageIO for sRGB declarations.
        var colorPNG: Data?
        if image.pixels.colorSpace?.model != .rgb {
            var colorImage = image
            guard let pixel = Redraw.draw(
                image.pixels, width: 1, height: 1, space: CGColorSpace(name: CGColorSpace.sRGB),
                bitsPerComponent: 8, alpha: false)
            else { throw .encodeFailed("Can't prepare palette color profile") }
            colorImage.pixels = pixel
            var colorPlan = losslessPlan
            colorPlan.keepMetadata = false
            colorPNG = try Encode.encode(colorImage, colorPlan).data
        }
        let data = try PNGChunks.finalizePalette(best, using: lossless.data, colorFrom: colorPNG)
        guard data.count < lossless.data.count else { return keptFullColor }
        let notes: [Note] = image.facts.hasGainMap ? [.hdrRemoved] : []
        return EncodedImage(
            data: data, format: .png, pixelWidth: source.width, pixelHeight: source.height,
            notes: image.notes + notes)
    }

    /// Find the smallest passing palette at full dither. Test that size and the next at each dither level.
    /// Keep the smallest passing output.
    struct Search {
        struct Trial: Hashable {
            var colors: Int
            var dither: Float
        }

        let source: PixelBuffer
        let floor: Double
        // Tests may supply a controlled PNG; scoring and acceptance always use the real path.
        private let candidate: ((Int, Float) throws(CodecError) -> Data)?
        private(set) var results: [Trial: (data: Data, passes: Bool)] = [:]

        init(source: PixelBuffer, floor: Double, candidate: ((Int, Float) throws(CodecError) -> Data)? = nil) {
            self.source = source
            self.floor = floor
            self.candidate = candidate
        }

        /// The smallest passing palette PNG, or nil when no palette meets the floor.
        mutating func run() throws(CodecError) -> Data? {
            let sizes = PNGPalette.paletteSizes
            // 1. Binary search for the smallest size passing at dither 1 (≤ 3 trials for 5 sizes).
            var low = 0
            var high = sizes.count
            while low < high {
                let mid = (low + high) / 2
                if try trial(Trial(colors: sizes[mid], dither: 1)).passes { high = mid } else { low = mid + 1 }
            }
            guard low < sizes.count else { return nil }

            // 2. Refine over that size and the next one up × every dither level.
            var best: Data?
            for colors in sizes[low...].prefix(2) {
                for dither in PNGPalette.ditherLevels {
                    let result = try trial(Trial(colors: colors, dither: dither))
                    if result.passes, result.data.count < best?.count ?? .max { best = result.data }
                }
            }
            return best
        }

        private mutating func trial(_ t: Trial) throws(CodecError) -> (data: Data, passes: Bool) {
            if let cached = results[t] { return cached }
            let data: Data
            if let candidate {
                data = try candidate(t.colors, t.dither)
            } else {
                let quantized = source.bytes.withUnsafeBytes { buf in
                    Result { () throws(QuantizrError) in
                        try Quantizr.quantize(
                            rgba: buf, width: source.width, height: source.height, bytesPerRow: source.bytesPerRow,
                            maxColors: t.colors, dither: t.dither, oxipngLevel: 2)
                    }
                }
                guard case .success(let encoded) = quantized else {
                    throw .encodeFailed("quantizr: \(quantized)")
                }
                data = encoded
            }
            let result = (data: data, passes: try PNGPalette.score(data, against: source) >= floor)
            results[t] = result
            return result
        }
    }

    /// Return the lower SSIMULACRA2 score over gray backgrounds of 0.1 and 0.9, matching the benchmark CLI.
    static func score(_ png: Data, against source: PixelBuffer) throws(CodecError) -> Double {
        guard let src = CGImageSourceCreateWithData(png as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw .encodeFailed("quantizr: output is not a readable PNG") }
        // The palette PNG has no profile yet; its values are the source's, so render without conversion.
        let distorted = try PixelBuffer.render(decoded, layout: .rgba8, sourceProfile: nil)
        guard distorted.width == source.width, distorted.height == source.height else {
            throw .encodeFailed("quantizr: output size differs from the source")
        }
        let backgrounds: [UInt8] = source.hasTransparency ? [26, 230] : [0]
        var worst = Double.infinity
        for background in backgrounds {
            let a = source.blendedRGB(onto: background)
            let b = distorted.blendedRGB(onto: background)
            let scored = a.withUnsafeBytes { ra in
                b.withUnsafeBytes { rb in
                    Result { () throws(JpegliError) in
                        try Jpegli.ssimulacra2(
                            reference: ra, distorted: rb, width: source.width, height: source.height,
                            bytesPerRow: source.width * 3, components: .rgb)
                    }
                }
            }
            guard case .success(let score) = scored else { throw .encodeFailed("SSIMULACRA2: \(scored)") }
            worst = min(worst, score)
        }
        return worst
    }
}

extension PixelBuffer {
    /// True when an `.rgba8` buffer has any alpha below 255.
    var hasTransparency: Bool {
        guard layout == .rgba8 else { return false }
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width where bytes[row + x * 4 + 3] != 255 { return true }
        }
        return false
    }

    /// Packed RGB of an `.rgba8` buffer blended onto a gray background, in the encoded (sRGB) values.
    func blendedRGB(onto background: UInt8) -> [UInt8] {
        precondition(layout == .rgba8)
        var out = [UInt8](repeating: 0, count: width * height * 3)
        let bg = UInt32(background)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                let a = UInt32(bytes[p + 3])
                let o = (y * width + x) * 3
                for c in 0..<3 {
                    out[o + c] = UInt8((UInt32(bytes[p + c]) * a + bg * (255 - a) + 127) / 255)
                }
            }
        }
        return out
    }
}
