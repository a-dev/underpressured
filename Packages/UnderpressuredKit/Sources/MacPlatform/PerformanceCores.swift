import UnderpressuredCore
import UnderpressuredApplication
import Foundation

/// How many Items the Queue processes at once: one per performance core (spec §7.7).
public enum PerformanceCores {
    /// The performance-core count, or `fallback` where the system gives none. Never below 1.
    public static func count(
        sysctl: (String) -> Int? = PerformanceCores.sysctlInt,
        fallback: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> Int {
        if let cores = sysctl("hw.perflevel0.physicalcpu"), cores > 0 { return cores }
        return max(fallback, 1)
    }

    /// Reads an integer sysctl value, or nil when the name is unknown.
    public static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
