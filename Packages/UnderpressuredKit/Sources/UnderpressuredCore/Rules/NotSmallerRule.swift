/// Whether a finished encode is worth writing (spec §7.3 step 8).
public enum NotSmallerRule {
    /// Skip non-smaller output only if format and pixel size are unchanged. Always write conversions and resizes.
    public static func decide(
        sourceFormat: ImageFormat,
        sourcePixelWidth: Int,
        sourcePixelHeight: Int,
        sourceBytes: Int64,
        outputFormat: WritableFormat,
        outputPixelWidth: Int,
        outputPixelHeight: Int,
        outputBytes: Int64
    ) -> Decision {
        let converted = outputFormat.imageFormat != sourceFormat
        let resized = outputPixelWidth != sourcePixelWidth || outputPixelHeight != sourcePixelHeight
        if converted || resized {
            return .write
        }
        return outputBytes >= sourceBytes ? .skip(.alreadyOptimal) : .write
    }

    public enum Decision: Sendable, Hashable {
        case write
        case skip(SkipReason)
    }
}
