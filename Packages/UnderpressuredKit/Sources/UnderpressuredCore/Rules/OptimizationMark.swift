import Foundation

/// Domain facts recorded for an output image so repeat processing can be recognized.
/// The adapter owns how these facts are stored and which stored versions it accepts.
public struct OptimizationMark: Sendable, Hashable {
    /// The Preset's settings without its name.
    public var settings: EffectiveSettings
    /// The resolved Output Format (§5), not the picker's value.
    public var outputFormat: WritableFormat
    /// The file's size at write time.
    public var size: Int64
    /// The file's modification date at write time.
    public var modificationDate: Date

    public init(
        settings: EffectiveSettings, outputFormat: WritableFormat,
        size: Int64, modificationDate: Date
    ) {
        self.settings = settings
        self.outputFormat = outputFormat
        self.size = size
        self.modificationDate = modificationDate
    }

    /// Compare whole milliseconds to absorb floating-point noise from JSON dates without rounding to whole seconds.
    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// Valid only while the file's size and modification date still match (§7.5).
    public func isValid(for attributes: FileAttributes) -> Bool {
        attributes.size == size
            && Self.milliseconds(attributes.modificationDate) == Self.milliseconds(modificationDate)
    }

    /// Whether this mark was made for exactly these settings and Output Format (§7.3 step 1).
    public func matches(settings: EffectiveSettings, outputFormat: WritableFormat) -> Bool {
        self.settings == settings && self.outputFormat == outputFormat
    }
}
