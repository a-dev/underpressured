import Foundation
import Testing
@testable import Underpressured

extension NativeAppTests {
    @Test func directDebugBuildHasNoProductionUpdaterConfiguration() {
        #expect(DirectUpdateConfiguration.mode == .disabled)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") == nil)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool == false)
        #expect(Bundle.main.object(forInfoDictionaryKey: "SUAllowsAutomaticUpdates") as? Bool == false)
        #expect(DirectUpdateConfiguration.frameworkVersion == "2.10.0")
    }

    @Test func directUpdaterPolicyRequiresFixtureOptIn() {
        #expect(DirectUpdateConfiguration.mode(info: [:], isTesting: false) == .disabled)
        #expect(DirectUpdateConfiguration.mode(info: ["UPUpdateMode": "release"], isTesting: false) == .disabled)
        #expect(DirectUpdateConfiguration.mode(info: ["UPUpdateMode": "fixture"], isTesting: false) == .fixture)
        #expect(DirectUpdateConfiguration.mode(info: ["UPUpdateMode": "fixture"], isTesting: true) == .fixture)
    }
}
