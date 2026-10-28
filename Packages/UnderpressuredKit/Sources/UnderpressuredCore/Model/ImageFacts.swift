import Foundation

public struct ImageInfo: Sendable, Hashable {
    public var format: ImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// More than 1 means animated (or multi-page for TIFF), which v0 skips (§7.2).
    public var frameCount: Int

    public init(format: ImageFormat, pixelWidth: Int, pixelHeight: Int, frameCount: Int = 1) {
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.frameCount = frameCount
    }

    public var pixelCount: Int { pixelWidth * pixelHeight }
}

/// What to do to the pixels (§7.3 step 5).
public struct TransformPlan: Sendable, Hashable {
    public var resizeRule: ResizeRule
    /// For JPEG output: flatten transparency onto white.
    public var flattenOntoWhite: Bool

    public init(resizeRule: ResizeRule, flattenOntoWhite: Bool) {
        self.resizeRule = resizeRule
        self.flattenOntoWhite = flattenOntoWhite
    }
}

/// How to encode (§7.3 steps 6–7, §7.4).
public struct EncodePlan: Sendable, Hashable {
    public var format: WritableFormat
    public var quality: Quality
    public var lossless: Bool
    public var keepMetadata: Bool

    public init(format: WritableFormat, quality: Quality, lossless: Bool, keepMetadata: Bool) {
        self.format = format
        self.quality = quality
        self.lossless = lossless
        self.keepMetadata = keepMetadata
    }
}
