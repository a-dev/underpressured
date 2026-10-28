import SwiftUI

/// The resolved bundle language owns text direction, independently of the desktop's language.
enum AppLocalization {
    static var languageIdentifier: String {
        Bundle.main.preferredLocalizations.first ?? Bundle.main.developmentLocalization ?? "en"
    }

    static var layoutDirection: LayoutDirection {
        Locale.Language(identifier: languageIdentifier).characterDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }
}
