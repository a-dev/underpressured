import UnderpressuredApplication
import Foundation
import Testing
@testable import AppModel
import UnderpressuredCore

@Suite struct LocalizationTests {
    @Test func packageResourcesResolveAndUnsupportedLanguageFallsBack() {
        // This value differs from its semantic key, so a missing bundle cannot pass by key echo.
        #expect(String(localized: "localization.bundle-check", bundle: .module, locale: Locale(identifier: "en")) == "English presentation resources")
        #expect(String(localized: "localization.bundle-check", bundle: .module, locale: Locale(identifier: "ko-KR")) == "English presentation resources")
        #expect(Bundle.module.localizations.contains("en"))
    }

    @Test func pluralMessagesAndPlaceholders() {
        for count in [0, 1, 2, 128] {
            var summary = RunSummary()
            summary.images = count
            summary.ignored = count
            let banner = Presentation.banner(summary, filter: nil)
            #expect(banner.text.hasPrefix(count == 1 ? "1 image ·" : "\(count) images ·"))
            if count > 0 {
                #expect(banner.text.hasSuffix(count == 1 ? "1 other file ignored" : "\(count) other files ignored"))
            }
        }
        #expect(AccessibilityText.presetPosition(name: "写真 %@", position: 2, count: 3) == "写真 %@ preset, position 2 of 3")
    }

    @Test func percentFormattingRespectsSignAndRounding() {
        #expect(Presentation.percentText(Savings(originalBytes: 1000, newBytes: 500)) == "-50%")
        #expect(Presentation.percentText(Savings(originalBytes: 1000, newBytes: 1180)) == "+18%")
        #expect(Presentation.percentText(Savings(originalBytes: 1000, newBytes: 1001)) == "0%")
    }
}

@Suite struct TranslatedResourceTests {
    static let languages = ["es", "pt-BR", "de", "fr", "ar", "ja", "zh-Hans"]

    @Test(arguments: languages)
    func compiledTranslationsAndPluralBoundaries(language: String) throws {
        let path = try #require(Bundle.module.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let locale = Locale(identifier: language)
        let probe = bundle.localizedString(forKey: "localization.bundle-check", value: nil, table: nil)
        #expect(probe != "localization.bundle-check")
        #expect(probe != "English presentation resources")
        for count in [0, 1, 2, 3, 10, 11, 99, 100, 101, 102, 103, 111, 200] {
            let images = String(localized: "run.images", defaultValue: "\(count) images", bundle: bundle, locale: locale)
            let ignored = String(localized: "run.ignored", defaultValue: "\(count) other files ignored", bundle: bundle, locale: locale)
            let quit = String(localized: "quit.remaining", defaultValue: "Cancel \(count) remaining images and quit?", bundle: bundle, locale: locale)
            let resized = String(localized: "note.resized.spoken", defaultValue: "resized from \("900") to \(count) pixels", bundle: bundle, locale: locale)
            for text in [images, ignored, quit, resized] {
                #expect(!text.contains("%lld"))
                #expect(!text.contains("%@"))
                #expect(text.contains(count.formatted(.number.grouping(.never).locale(locale))))
            }
            if language == "ar" {
                if count == 0 { #expect(images.contains("لا توجد")) }
                if count == 1 { #expect(images.contains("واحدة")) }
                if count == 2 { #expect(images.contains("صورتان")) }
                if [3, 10, 103].contains(count) { #expect(images.contains("صور")) }
            }
        }
        let userName = "صورة 12 — photo%@.jpg"
        let name = String(localized: "\(userName) preset", bundle: bundle, locale: locale)
        #expect(name.contains(userName))
    }

    @Test func regionalPreferenceMatching() {
        let available = ["en"] + Self.languages
        for (preference, expected) in [("es-MX", "es"), ("de-AT", "de"), ("fr-CA", "fr"), ("ar-EG", "ar"), ("ja-JP", "ja"), ("pt-BR", "pt-BR"), ("zh-CN", "zh-Hans"), ("zh-SG", "zh-Hans"), ("ko-KR", "en"), ("pt-PT", "pt-BR"), ("zh-TW", "en"), ("zh-HK", "en")] {
            #expect(Bundle.preferredLocalizations(from: available, forPreferences: [preference]).first == expected)
        }
    }
}
