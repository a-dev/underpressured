import UnderpressuredApplication
import Foundation
import UnderpressuredCore

extension Preset {
    /// Legacy and custom names remain user data; only explicitly identified starters are translated.
    public var displayName: String {
        switch starterID {
        case .balanced: String(localized: "Balanced JPEG", bundle: .module, comment: "Built-in preset converting to JPEG with balanced quality and size.")
        case .web: String(localized: "Web", bundle: .module, comment: "Built-in preset for images published on the web.")
        case .screenshots: String(localized: "Screenshots PNG", bundle: .module, comment: "Built-in preset converting screenshots to PNG.")
        case .small: String(localized: "Small", bundle: .module, comment: "Built-in preset producing smaller images.")
        case nil: name
        }
    }
}
