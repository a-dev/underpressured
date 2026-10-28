import UnderpressuredApplication
import Accelerate
import CoreGraphics
import UnderpressuredCore

/// Resizes with vImage Lanczos in linear light. Premultiplied alpha prevents halos.
/// Preserves the source color space, bit depth, and alpha.
enum Resize {
    static func apply(_ rule: ResizeRule, to image: DecodedImage) throws(CodecError) -> DecodedImage {
        let width = image.pixels.width
        let height = image.pixels.height
        guard let (newWidth, newHeight) = targetSize(rule, width: width, height: height) else { return image }

        var result = image
        result.pixels = try scale(image.pixels, toWidth: newWidth, height: newHeight)
        result.pixelsTransformed = true
        result.notes.append(.resized(from: max(width, height), to: max(newWidth, newHeight)))
        return result
    }

    /// The size after the rule, or nil when the image is already within the limit (never upscales).
    static func targetSize(_ rule: ResizeRule, width: Int, height: Int) -> (Int, Int)? {
        let limit: Int
        let edge: Int
        switch rule {
        case .none: return nil
        case .maxWidth(let n): (limit, edge) = (n.rawValue, width)
        case .maxHeight(let n): (limit, edge) = (n.rawValue, height)
        case .maxLongEdge(let n): (limit, edge) = (n.rawValue, max(width, height))
        }
        guard limit >= 1, edge > limit else { return nil }
        let factor = Double(limit) / Double(edge)
        func scaled(_ value: Int) -> Int { value == edge ? limit : max(1, Int((Double(value) * factor).rounded())) }
        return (scaled(width), scaled(height))
    }

    // MARK: Scaling

    private static let floatInfo = CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private static func fail(_ what: String) -> CodecError { .encodeFailed("resize: \(what)") }

    static func scale(
        _ source: CGImage, toWidth newWidth: Int, height newHeight: Int,
        allocateBuffer: (Int, Int, Int) throws(CodecError) -> vImage_Buffer = makeBuffer,
        freeBuffer: (vImage_Buffer) -> Void = releaseBuffer
    ) throws(CodecError) -> CGImage {
        let sourceSpace = source.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let model = sourceSpace.model
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast, .alphaOnly].contains(source.alphaInfo)

        // Output space: the source's own for gray, RGB and CMYK; sRGB for anything exotic (indexed, Lab).
        let outputSpace: CGColorSpace
        switch model {
        case .monochrome, .rgb, .cmyk: outputSpace = sourceSpace
        default: outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
        let planar = model == .monochrome && !hasAlpha
        let workSpace: CGColorSpace
        if planar, let space = CGColorSpaceCreateExtendedLinearized(sourceSpace) {
            workSpace = space
        } else if planar, let space = CGColorSpace(name: CGColorSpace.linearGray) {
            workSpace = space
        } else if model == .rgb, let space = CGColorSpaceCreateExtendedLinearized(sourceSpace) {
            workSpace = space
        } else if let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) {
            workSpace = space
        } else {
            throw fail("no linear color space")
        }
        let channels = planar ? 1 : 4
        let alphaInfo = planar ? CGImageAlphaInfo.none : .premultipliedLast

        var src = try allocateBuffer(source.width, source.height, channels)
        defer { freeBuffer(src) }
        var dst = try allocateBuffer(newWidth, newHeight, channels)
        defer { freeBuffer(dst) }
        try draw(source, into: src, space: workSpace, bitmapInfo: floatInfo | alphaInfo.rawValue, bitsPerComponent: 32)

        let flags = vImage_Flags(kvImageHighQualityResampling)
        let error: vImage_Error
        if planar {
            error = vImageScale_PlanarF(&src, &dst, nil, flags)
        } else {
            error = vImageScale_ARGBFFFF(&src, &dst, nil, flags)
        }
        guard error == kvImageNoError else { throw fail("vImageScale (\(error))") }
        if !planar { clampAlpha(dst) }

        guard let linear = makeFloatImage(dst, space: workSpace, channels: channels, alphaInfo: alphaInfo) else {
            throw fail("cannot wrap scaled pixels")
        }
        return try render(linear, space: outputSpace, like: source, hasAlpha: hasAlpha)
    }

    /// Float working buffers reach hundreds of MB. They are mapped directly because libmalloc keeps freed blocks
    /// of this size resident and dirty after the resize.
    private static func makeBuffer(width: Int, height: Int, channels: Int) throws(CodecError) -> vImage_Buffer {
        var buffer = vImage_Buffer()
        let error = vImageBuffer_Init(
            &buffer, vImagePixelCount(height), vImagePixelCount(width), UInt32(32 * channels),
            vImage_Flags(kvImageNoAllocate))
        guard error >= 0 else { throw fail("buffer \(width)x\(height) (\(error))") }
        let data = mmap(nil, buffer.rowBytes * Int(buffer.height), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)
        guard let data, data != MAP_FAILED else { throw fail("buffer \(width)x\(height) (errno \(errno))") }
        buffer.data = data
        return buffer
    }

    private static func releaseBuffer(_ buffer: vImage_Buffer) {
        munmap(buffer.data, buffer.rowBytes * Int(buffer.height))
    }

    private static func draw(
        _ image: CGImage, into buffer: vImage_Buffer, space: CGColorSpace, bitmapInfo: UInt32, bitsPerComponent: Int
    ) throws(CodecError) {
        guard
            let context = CGContext(
                data: buffer.data, width: Int(buffer.width), height: Int(buffer.height), bitsPerComponent: bitsPerComponent,
                bytesPerRow: buffer.rowBytes, space: space, bitmapInfo: bitmapInfo)
        else { throw fail("cannot create \(bitsPerComponent)-bit context") }
        context.interpolationQuality = .none
        context.setShouldAntialias(false)
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: Int(buffer.width), height: Int(buffer.height)))
    }

    /// Lanczos overshoots; keep premultiplied alpha within 0...1 so the final conversion stays sane.
    private static func clampAlpha(_ buffer: vImage_Buffer) {
        let width = Int(buffer.width)
        for y in 0..<Int(buffer.height) {
            let row = (buffer.data + y * buffer.rowBytes).assumingMemoryBound(to: Float.self)
            for x in 0..<width { row[x * 4 + 3] = min(max(row[x * 4 + 3], 0), 1) }
        }
    }

    private static func makeFloatImage(
        _ buffer: vImage_Buffer, space: CGColorSpace, channels: Int, alphaInfo: CGImageAlphaInfo
    ) -> CGImage? {
        let bytes = Int(buffer.rowBytes) * Int(buffer.height)
        guard
            let provider = CGDataProvider(
                dataInfo: nil, data: buffer.data, size: bytes, releaseData: { _, _, _ in })
        else { return nil }
        return CGImage(
            width: Int(buffer.width), height: Int(buffer.height), bitsPerComponent: 32, bitsPerPixel: 32 * channels,
            bytesPerRow: buffer.rowBytes, space: space, bitmapInfo: CGBitmapInfo(rawValue: floatInfo | alphaInfo.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Draws the linear float image 1:1 into a bitmap with the source's bit depth and alpha presence.
    private static func render(
        _ linear: CGImage, space: CGColorSpace, like source: CGImage, hasAlpha: Bool
    ) throws(CodecError) -> CGImage {
        let bits = source.bitsPerComponent == 16 ? 16 : 8
        let info: CGImageAlphaInfo
        switch space.model {
        case .monochrome: info = hasAlpha ? .premultipliedLast : .none
        case .cmyk: info = .none
        default: info = hasAlpha ? .premultipliedLast : .noneSkipLast
        }
        let components = space.numberOfComponents + (info == .none ? 0 : 1)
        let bytesPerRow = linear.width * components * bits / 8
        var data = [UInt8](repeating: 0, count: bytesPerRow * linear.height)
        let image: CGImage? = data.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: linear.width, height: linear.height, bitsPerComponent: bits,
                    bytesPerRow: bytesPerRow, space: space, bitmapInfo: info.rawValue)
            else { return nil }
            context.interpolationQuality = .none
            context.setShouldAntialias(false)
            context.setBlendMode(.copy)
            context.draw(linear, in: CGRect(x: 0, y: 0, width: linear.width, height: linear.height))
            return context.makeImage()
        }
        guard let image else { throw fail("cannot render \(bits)-bit output") }
        return image
    }
}
