import Foundation

/// Unicode isolation keeps filename punctuation and path separators inside the data's direction.
enum FileText {
    static func name(_ value: String) -> String { "\u{2068}\(value)\u{2069}" }
    static func path(_ value: String) -> String { "\u{2066}\(value)\u{2069}" }
}
