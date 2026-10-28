import UnderpressuredApplication
import CoreGraphics
import Foundation
import ImageIO
import UnderpressuredCore

/// Decodes and encodes with ImageIO. Resizes with vImage.
public struct ImageIOCodec: ImageCodec {
    public typealias Image = DecodedImage

    public init() {}

    public func inspect(_ data: Data) async throws(CodecError) -> ImageInfo {
        try Decode.inspect(data)
    }

    public func decode(_ data: Data) async throws(CodecError) -> DecodedImage {
        try Decode.decode(data)
    }

    public func transform(_ image: DecodedImage, _ plan: TransformPlan) async throws(CodecError) -> DecodedImage {
        try Self.transform(image, plan)
    }

    static func transform(_ image: DecodedImage, _ plan: TransformPlan) throws(CodecError) -> DecodedImage {
        var image = try Resize.apply(plan.resizeRule, to: image)
        if plan.flattenOntoWhite { image = try Flatten.ontoWhite(image) }
        return image
    }

    public func encode(_ image: DecodedImage, _ plan: EncodePlan) async throws(CodecError) -> EncodedImage {
        try Encode.encode(image, plan)
    }
}

/// Decoded pixels plus the source facts the later stages need. Immutable once built.
public struct DecodedImage: @unchecked Sendable {
    /// Upright (orientation applied), in the source color space and bit depth.
    public var pixels: CGImage
    public var facts: SourceFacts
    /// Source metadata as read (EXIF, XMP, IPTC, GPS), for Keep metadata (Metadata.swift).
    public var metadata: SourceMetadata
    /// Notes earned so far (e.g. resized), passed through to `EncodedImage.notes`.
    public var notes: [Note]
    /// The file as read, for encoders that work on the source bytes (the lossless JPEG rewrite).
    public var sourceData: Data?
    /// True once a transform (resize, flatten) changed the pixels, so the source bytes no longer match.
    public var pixelsTransformed: Bool

    public init(
        pixels: CGImage, facts: SourceFacts, metadata: SourceMetadata, notes: [Note] = [],
        sourceData: Data? = nil, pixelsTransformed: Bool = false
    ) {
        self.pixels = pixels
        self.facts = facts
        self.metadata = metadata
        self.notes = notes
        self.sourceData = sourceData
        self.pixelsTransformed = pixelsTransformed
    }
}

/// Facts about the source that decide how to encode (§7.4).
public struct SourceFacts: Sendable, Hashable {
    public var format: ImageFormat
    public var bitsPerComponent: Int
    public var isGrayscale: Bool
    public var isCMYK: Bool
    public var hasAlpha: Bool
    public var hasGainMap: Bool
    /// The embedded ICC profile, carried unchanged to the output.
    public var iccProfile: Data?

    public init(
        format: ImageFormat, bitsPerComponent: Int, isGrayscale: Bool, isCMYK: Bool, hasAlpha: Bool,
        hasGainMap: Bool, iccProfile: Data?
    ) {
        self.format = format
        self.bitsPerComponent = bitsPerComponent
        self.isGrayscale = isGrayscale
        self.isCMYK = isCMYK
        self.hasAlpha = hasAlpha
        self.hasGainMap = hasGainMap
        self.iccProfile = iccProfile
    }
}

/// The source's metadata, kept opaque to the other stages. Filled by Decode, written by Metadata.
public struct SourceMetadata: @unchecked Sendable {
    /// `CGImageSourceCopyPropertiesAtIndex` of the primary image.
    public var properties: [CFString: Any]
    /// `CGImageSourceCopyMetadataAtIndex` (XMP tree), if any.
    public var xmp: CGImageMetadata?

    public init(properties: [CFString: Any] = [:], xmp: CGImageMetadata? = nil) {
        self.properties = properties
        self.xmp = xmp
    }
}
