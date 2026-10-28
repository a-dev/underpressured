import UnderpressuredApplication
import Foundation
import UnderpressuredCore

extension Presentation {
    public static func footer(_ summary: RunSummary?, isRunning: Bool) -> FooterState {
        guard let summary else { return FooterState(isRunning: isRunning, progressText: nil, savingsText: nil) }
        var footer = FooterState(
            isRunning: isRunning,
            progressText: isRunning ? String(localized: "\(summary.finished.formatted()) / \(summary.images.formatted())", bundle: .module, comment: "Finished count / total image count in progress indicator.") : nil,
            savingsText: savingsText(summary))
        let savings = spokenSavings(summary)
        footer.spokenLabel = isRunning
            ? String(localized: "\(summary.finished.formatted()) of \(summary.images.formatted()) finished, \(savings)", bundle: .module, comment: "Spoken progress. Finished count, total count, then a complete savings phrase.")
            : savings
        return footer
    }

    public static func banner(_ summary: RunSummary, filter: OutcomeFilter?) -> Banner {
        let images = String(localized: "run.images", defaultValue: "\(summary.images) images", bundle: .module, comment: "Total image count in a completed run. Use plural variations.")
        let buttons = OutcomeFilter.allCases.filter { summary.count($0) > 0 }.map {
            Banner.FilterButton(filter: $0, title: title(for: $0, count: summary.count($0)), isOn: $0 == filter)
        }
        var text = joined(images, savingsText(summary))
        var speech = AccessibilityText.joined(images, spokenSavings(summary))
        for button in buttons {
            text = joined(text, button.title)
            speech = AccessibilityText.joined(speech, button.title)
        }
        if summary.ignored > 0 {
            let ignored = String(localized: "run.ignored", defaultValue: "\(summary.ignored) other files ignored", bundle: .module, comment: "Non-image files ignored during scanning. Use plural variations.")
            text = joined(text, ignored)
            speech = AccessibilityText.joined(speech, ignored)
        }
        var banner = Banner(text: text, filters: buttons)
        banner.spokenLabel = speech
        return banner
    }

    /// Translator-controlled joining of complete summary phrases, never English word fragments.
    static func joined(_ summary: String, _ detail: String) -> String {
        String(localized: "\(summary) · \(detail)", bundle: .module, comment: "Join complete result summary phrases. Placeholders are already localized; punctuation/order may change.")
    }

    static func savingsText(_ summary: RunSummary) -> String {
        guard summary.optimized > 0 else { return String(localized: "nothing optimized", bundle: .module, comment: "Run summary when no image was optimized.") }
        let savings = summary.savings
        let percent = (Double(roundedPercent(savings)) / 100).formatted(.percent.precision(.fractionLength(0)))
        if savings.bytes < 0 {
            return String(localized: "\(size(-savings.bytes)) larger (\(percent))", bundle: .module, comment: "Run growth: formatted byte increase and formatted percentage including its percent sign.")
        }
        return String(localized: "\(size(savings.bytes)) saved (\(percent))", bundle: .module, comment: "Run savings: formatted bytes saved and formatted percentage including its percent sign.")
    }

    static func spokenSavings(_ summary: RunSummary) -> String {
        guard summary.optimized > 0 else { return String(localized: "nothing optimized", bundle: .module, comment: "Run summary when no image was optimized.") }
        let savings = summary.savings
        let percent = roundedPercent(savings).formatted()
        if savings.bytes < 0 {
            return String(localized: "\(size(-savings.bytes)) larger, \(percent) percent", bundle: .module, comment: "Spoken run growth. Formatted bytes then whole percentage number without percent sign.")
        }
        return String(localized: "\(size(savings.bytes)) saved, \(percent) percent", bundle: .module, comment: "Spoken run savings. Formatted bytes then whole percentage number without percent sign.")
    }

    static func title(for filter: OutcomeFilter, count: Int) -> String {
        switch filter {
        case .failed: String(localized: "\(count) failed", bundle: .module, comment: "Number of images that failed processing. Use plural variations if required.")
        case .skipped: String(localized: "\(count) skipped", bundle: .module, comment: "Number of skipped images. Use plural variations if required.")
        case .cancelled: String(localized: "\(count) cancelled", bundle: .module, comment: "Number of images cancelled. Use plural variations if required.")
        }
    }
}
