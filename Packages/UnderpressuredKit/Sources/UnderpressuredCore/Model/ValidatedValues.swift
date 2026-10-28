import Foundation

/// Compression quality normalized to the product's inclusive 0–100 range.
public struct Quality: Sendable, Hashable, Comparable, ExpressibleByIntegerLiteral {
    public let rawValue: Int
    private init(_ value: Int) { rawValue = value }
    public static func clamping(_ value: Int) -> Self { Self(min(max(value, 0), 100)) }
    public init(integerLiteral value: Int) { self = .clamping(value) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A resize limit in pixels, normalized to at least one pixel.
public struct PixelLimit: Sendable, Hashable, ExpressibleByIntegerLiteral {
    public let rawValue: Int
    private init(_ value: Int) { rawValue = value }
    public static func clamping(_ value: Int) -> Self { Self(max(value, 1)) }
    public init(integerLiteral value: Int) { self = .clamping(value) }
}
