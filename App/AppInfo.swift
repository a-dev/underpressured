import Foundation

enum AppInfo {
    static let documentationURL = URL(string: "https://underpressured.app")!
    static let privacyPolicyURL = URL(string: "https://underpressured.app/privacy/")!

    static let supportEmail = "support@underpressured.app"
    static let supportURL = URL(string: "mailto:\(supportEmail)")!

    static let repositoryURL = URL(string: "https://github.com/a-dev/underpressured")!
    static let issuesURL = URL(string: "https://github.com/a-dev/underpressured/issues")!

    static let translationContributionURL: URL = {
        var components = URLComponents(string: "https://github.com/a-dev/underpressured/issues/new")!
        components.queryItems = [
            URLQueryItem(name: "title", value: String(localized: "Translation contribution", bundle: .main)),
            URLQueryItem(
                name: "body",
                value: String(localized: "Language:\n\nWhat would you like to translate or improve?\n", bundle: .main))
        ]
        return components.url!
    }()
}
