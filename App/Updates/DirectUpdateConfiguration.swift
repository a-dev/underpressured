#if DIRECT_DISTRIBUTION
import Foundation
import Sparkle

/// App-owned packaging policy, checked before constructing the standard controller.
/// Importing the framework alone does not create or start an updater controller.
enum DirectUpdateConfiguration {
    enum Mode: String {
        case disabled
        case fixture
        case release
    }

    static var mode: Mode {
        mode(info: Bundle.main.infoDictionary ?? [:], isTesting: NSClassFromString("XCTestCase") != nil)
    }

    static func mode(info: [String: Any], isTesting: Bool) -> Mode {
        #if DEBUG
        return info["UPUpdateMode"] as? String == "fixture" ? .fixture : .disabled
        #else
        guard !isTesting else { return .disabled }
        return info["UPUpdateMode"] as? String == "release" ? .release : .disabled
        #endif
    }

    static var frameworkVersion: String? {
        Bundle(for: SPUUpdater.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}
#endif
