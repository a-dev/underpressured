import UnderpressuredApplication
import Accelerate
import CoreGraphics
import Foundation
import Testing
import UnderpressuredCore
@testable import ImageEngine

private func makeImage(
    width: Int, height: Int, space: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!, bits: Int = 8,
    alpha: CGImageAlphaInfo = .noneSkipLast, fill: (Int, Int) -> [Double] = { x, y in [Double(x % 256) / 255, Double(y % 256) / 255, 0.5] }
) throws -> CGImage {
    let comps = space.numberOfComponents + (alpha == .none ? 0 : 1)
    let bytesPerRow = width * comps * bits / 8
    var data = [UInt8](repeating: 0, count: bytesPerRow * height)
    let image: CGImage? = data.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: bits, bytesPerRow: bytesPerRow, space: space, bitmapInfo: alpha.rawValue) else { return nil }
        for y in 0..<height {
            for x in 0..<width {
                let v = fill(x, y)
                let c = (0..<space.numberOfComponents).map { CGFloat(v[min($0, v.count - 1)]) } + [1]
                ctx.setFillColor(CGColor(colorSpace: space, components: c)!)
                ctx.fill(CGRect(x: x, y: height - 1 - y, width: 1, height: 1))
            }
        }
        return ctx.makeImage()
    }
    return try #require(image)
}

private func decoded(_ pixels: CGImage, gray: Bool = false, bits: Int = 8) -> DecodedImage {
    DecodedImage(
        pixels: pixels,
        facts: SourceFacts(format: .jpeg, bitsPerComponent: bits, isGrayscale: gray, isCMYK: false, hasAlpha: false, hasGainMap: false, iccProfile: nil),
        metadata: SourceMetadata())
}

private func alphaFixture() throws -> CGImage {
    let width = 64, height = 48
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var data = [UInt8](repeating: 0, count: width * height * 4)
    let image: CGImage? = data.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setBlendMode(.copy)
        // Transparent green, half-transparent red, and opaque blue stripes.
        for (x, color) in [(0..<21, [0.0, 1.0, 0.0, 0.0]), (21..<43, [1.0, 0.0, 0.0, 0.5]), (43..<64, [0.0, 0.0, 1.0, 1.0])] {
            context.setFillColor(CGColor(colorSpace: space, components: color.map { CGFloat($0) })!)
            context.fill(CGRect(x: x.lowerBound, y: 0, width: x.count, height: height))
        }
        return context.makeImage()
    }
    return try #require(image)
}

private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered: CGImage? = bytes.withUnsafeMutableBytes { raw in
        guard let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
    _ = try #require(rendered)
    return bytes
}

private func size(_ r: ResizeRule, _ w: Int, _ h: Int) throws -> (Int, Int) {
    let out = try Resize.apply(r, to: decoded(makeImage(width: w, height: h)))
    return (out.pixels.width, out.pixels.height)
}

@Suite struct ResizeTests {
    @Test func resize_freesSourceWhenDestinationAllocationFails() throws {
        var allocated: [UnsafeMutableRawPointer] = []
        var freed: [UnsafeMutableRawPointer] = []
        let image = try makeImage(width: 16, height: 16)
        let allocator: (Int, Int, Int) throws(CodecError) -> vImage_Buffer = { width, height, channels in
            guard allocated.isEmpty else { throw CodecError.encodeFailed("injected destination allocation failure") }
            var buffer = vImage_Buffer()
            let error = vImageBuffer_Init(&buffer, vImagePixelCount(height), vImagePixelCount(width), UInt32(channels * 32), vImage_Flags(kvImageNoFlags))
            guard error == kvImageNoError, let data = buffer.data else { throw CodecError.encodeFailed("test allocation failed") }
            allocated.append(data)
            return buffer
        }
        #expect(throws: CodecError.self) {
            try Resize.scale(image, toWidth: 8, height: 8, allocateBuffer: allocator, freeBuffer: { buffer in
                if let pointer = buffer.data {
                    freed.append(pointer)
                    free(pointer)
                }
            })
        }
        #expect(freed.count == 1)
        #expect(Set(freed.map { UInt(bitPattern: $0) }) == Set(allocated.map { UInt(bitPattern: $0) }))
    }

    @Test func resize_freesBothBuffersOnceAfterSuccess() throws {
        var allocated: [UnsafeMutableRawPointer] = []
        var freed: [UnsafeMutableRawPointer] = []
        let image = try makeImage(width: 16, height: 16)
        let allocator: (Int, Int, Int) throws(CodecError) -> vImage_Buffer = { width, height, channels in
            var buffer = vImage_Buffer()
            let error = vImageBuffer_Init(&buffer, vImagePixelCount(height), vImagePixelCount(width), UInt32(channels * 32), vImage_Flags(kvImageNoFlags))
            guard error == kvImageNoError, let data = buffer.data else { throw CodecError.encodeFailed("test allocation failed") }
            allocated.append(data)
            return buffer
        }
        let output = try Resize.scale(image, toWidth: 8, height: 8, allocateBuffer: allocator, freeBuffer: { buffer in
            if let pointer = buffer.data { freed.append(pointer); free(pointer) }
        })
        #expect(output.width == 8 && output.height == 8)
        #expect(Set(freed.map { UInt(bitPattern: $0) }) == Set(allocated.map { UInt(bitPattern: $0) }))
        #expect(freed.count == 2)
    }

    @Test func resize_freesBothBuffersAfterOperationFailure() throws {
        var allocated: [UnsafeMutableRawPointer] = []
        var freed: [UnsafeMutableRawPointer] = []
        let image = try makeImage(width: 16, height: 16)
        let allocator: (Int, Int, Int) throws(CodecError) -> vImage_Buffer = { width, height, channels in
            var buffer = vImage_Buffer()
            let error = vImageBuffer_Init(&buffer, vImagePixelCount(height), vImagePixelCount(width), UInt32(channels * 32), vImage_Flags(kvImageNoFlags))
            guard error == kvImageNoError, let data = buffer.data else { throw CodecError.encodeFailed("test allocation failed") }
            allocated.append(data)
            if allocated.count == 1 { buffer.rowBytes = 0 }
            return buffer
        }
        #expect(throws: CodecError.encodeFailed("resize: cannot create 32-bit context")) {
            try Resize.scale(image, toWidth: 8, height: 8, allocateBuffer: allocator, freeBuffer: { buffer in
                if let pointer = buffer.data { freed.append(pointer); free(pointer) }
            })
        }
        #expect(freed.count == 2)
        #expect(Set(freed.map { UInt(bitPattern: $0) }) == Set(allocated.map { UInt(bitPattern: $0) }))
    }

    @Test func resize_spec7_3_longEdgeLandscapeRounds() throws {
        let big = try #require(Resize.targetSize(.maxLongEdge(2048), width: 4032, height: 3024))
        #expect(big == (2048, 1536))
        let (w2, h2) = try size(.maxLongEdge(100), 301, 200)
        #expect(w2 == 100 && h2 == 66)  // 66.45 rounds to 66
        let (w3, h3) = try size(.maxLongEdge(100), 299, 200)
        #expect(w3 == 100 && h3 == 67)  // 66.89 rounds to 67
    }

    @Test func resize_spec7_3_longEdgePortrait() throws {
        let (w, h) = try size(.maxLongEdge(100), 150, 300)
        #expect(w == 50 && h == 100)
    }

    @Test func resize_spec7_3_maxWidthAndHeight() throws {
        let (w, h) = try size(.maxWidth(100), 400, 300)
        #expect(w == 100 && h == 75)
        let (w2, h2) = try size(.maxHeight(100), 400, 300)
        #expect(w2 == 133 && h2 == 100)
        let (w3, h3) = try size(.maxWidth(100), 90, 300)  // portrait within width limit
        #expect(w3 == 90 && h3 == 300)
    }

    @Test func resize_spec7_3_noneAndWithinLimitUnchangedNoNote() throws {
        for rule in [ResizeRule.none, .maxWidth(400), .maxHeight(300), .maxLongEdge(400), .maxLongEdge(5000)] {
            let input = try decoded(makeImage(width: 400, height: 300))
            let out = try Resize.apply(rule, to: input)
            #expect(out.pixels === input.pixels)
            #expect(out.notes.isEmpty)
        }
    }

    @Test func resize_spec7_3_neverUpscales() throws {
        let (w, h) = try size(.maxLongEdge(10000), 40, 30)
        #expect(w == 40 && h == 30)
    }

    @Test func resize_spec7_3_note() throws {
        let out = try Resize.apply(.maxLongEdge(200), to: decoded(makeImage(width: 400, height: 300)))
        #expect(out.notes == [.resized(from: 400, to: 200)])
        let portrait = try Resize.apply(.maxHeight(100), to: decoded(makeImage(width: 200, height: 400)))
        #expect(portrait.notes == [.resized(from: 400, to: 100)])
    }

    @Test func resize_spec7_3_keeps16Bit() throws {
        let img = try makeImage(width: 64, height: 48, bits: 16, alpha: .noneSkipLast)
        let out = try Resize.apply(.maxLongEdge(32), to: decoded(img, bits: 16))
        #expect(out.pixels.bitsPerComponent == 16)
        #expect(out.pixels.width == 32 && out.pixels.height == 24)
    }

    @Test func resize_spec7_3_keepsGray() throws {
        let space = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!
        let img = try makeImage(width: 64, height: 48, space: space, alpha: .none) { x, _ in [Double(x) / 63] }
        let out = try Resize.apply(.maxLongEdge(32), to: decoded(img, gray: true))
        #expect(out.facts.isGrayscale)
        #expect(out.pixels.colorSpace?.model == .monochrome)
        #expect(out.pixels.width == 32 && out.pixels.height == 24)
    }

    @Test func resize_preservesTransparencyAndPremultipliedEdges() throws {
        let img = try alphaFixture()
        var input = decoded(img)
        input.facts.format = .png
        input.facts.hasAlpha = true
        let out = try Resize.apply(.maxLongEdge(32), to: input)
        #expect(out.pixels.alphaInfo == .premultipliedLast)
        let pixels = try rgbaPixels(out.pixels)
        func pixel(_ x: Int, _ y: Int = 12) -> [Double] {
            let offset = (y * out.pixels.width + x) * 4
            return (0..<4).map { Double(pixels[offset + $0]) / 255 }
        }
        // Well inside each stripe, alpha and color must survive the resize.
        let transparent = pixel(3)
        let translucent = pixel(16)
        let opaque = pixel(27)
        #expect(transparent[3] < 0.03)
        #expect(translucent[3] > 0.45 && translucent[3] < 0.55)
        #expect(opaque[3] > 0.97)
        #expect(translucent[0] > translucent[1] + 0.35 && translucent[0] > translucent[2] + 0.35)
        #expect(abs(translucent[0] - translucent[3]) < 0.03)
        #expect(translucent[1] < 0.02 && translucent[2] < 0.02)
        #expect(opaque[2] > opaque[0] + 0.7 && opaque[2] > opaque[1] + 0.7)

        // At the transparent/red boundary, premultiplied red must track alpha.
        let edge = pixel(10)
        #expect(edge[3] > 0.02 && edge[3] < 0.48)
        #expect(abs(edge[0] - edge[3]) < 0.03)
        #expect(edge[1] < 0.02 && edge[2] < 0.02)
        func composite(_ rgba: [Double], over background: Double) -> [Double] {
            (0..<3).map { rgba[$0] + background * (1 - rgba[3]) }
        }
        let onLight = composite(edge, over: 1)
        let onDark = composite(edge, over: 0)
        let expectedLight = [1.0, 1 - edge[3], 1 - edge[3]]
        let expectedDark = [edge[3], 0, 0]
        for channel in 0..<3 {
            #expect(abs(onLight[channel] - expectedLight[channel]) < 0.03)
            #expect(abs(onDark[channel] - expectedDark[channel]) < 0.03)
        }
    }

    @Test func resize_spec7_3_keepsDisplayP3() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let img = try makeImage(width: 64, height: 48, space: p3)
        let out = try Resize.apply(.maxLongEdge(32), to: decoded(img))
        #expect(out.pixels.colorSpace?.name as String? == CGColorSpace.displayP3 as String)
    }

    @Test func resize_spec7_3_linearLight() throws {
        let img = try makeImage(width: 64, height: 64) { x, y in
            let v: Double = (x + y) % 2 == 0 ? 0 : 1
            return [v, v, v]
        }
        let out = try Resize.apply(.maxLongEdge(32), to: decoded(img))
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = try #require(CGContext(
            data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.interpolationQuality = .none
        // Sample the centre pixel.
        ctx.draw(out.pixels, in: CGRect(x: -16, y: -16, width: 32, height: 32))
        #expect(abs(Int(px[0]) - 188) <= 4)
    }

    @Test func resize_spec7_3_cmykStaysCMYK() throws {
        let space = CGColorSpace(name: CGColorSpace.genericCMYK)!
        let img = try makeImage(width: 64, height: 48, space: space, alpha: .none) { x, _ in [Double(x) / 63, 0, 0, 0.2] }
        let out = try Resize.apply(.maxLongEdge(32), to: decoded(img))
        #expect(out.pixels.colorSpace?.model == .cmyk)
        #expect(out.pixels.width == 32)
    }
}
