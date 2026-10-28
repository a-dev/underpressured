import UnderpressuredApplication
import Foundation
import UnderpressuredCore

/// The kinds of Outcome the banner can filter the list by (spec §3.5).
public enum OutcomeFilter: Sendable, Hashable, CaseIterable {
    case failed
    case skipped
    case cancelled

    func matches(_ state: ItemState) -> Bool {
        switch (self, state) {
        case (.failed, .finished(.failed)), (.skipped, .finished(.skipped)),
             (.cancelled, .finished(.cancelled)): true
        default: false
        }
    }
}

/// One Item as the list shows it (spec §3.3). Every string is final; views only lay it out.
public struct ItemRow: Sendable, Hashable, Identifiable {
    public var id: Item.ID
    /// The file name.
    public var name: String
    /// The actual output extension when optimization changed it, including the leading dot.
    public var convertedExtension: String? = nil
    /// Folder path including the dropped root, such as "Trip/Day 1". Nil for loose files.
    public var folderPath: String?
    /// "Waiting", "Processing", "Optimized", "Skipped", "Failed" or "Cancelled".
    public var stateText: String
    /// Visible status text for outcomes that need attention.
    public var issueText: String? = nil
    public var isProcessing: Bool
    /// "4.2 MB → 1.1 MB", or nil before the Item is Optimized.
    public var sizesText: String?
    /// "−74%" for Savings, "+18%" for growth, "0%" if it rounds to nothing; nil before Optimized.
    public var savingsText: String?
    /// Negative Savings that show as "+N%", in a warning colour.
    public var isGrowth: Bool
    public var isReduction: Bool = false
    /// The reason (Skipped, Failed) or the notes (Optimized), or nil.
    public var detail: String?
    /// Open or preview the optimized output, skipped copy, or skipped source. Nil otherwise.
    /// The file may no longer exist. See `AppModel.openableURLs`.
    public var openURL: URL?
    var spokenLabel: String? = nil
}

/// The Items of one drop under a header: where they came from and the Preset used (spec §3.3).
public struct ItemSection: Sendable, Hashable, Identifiable {
    public var id: Batch.ID
    /// "~/Pictures/polygons", or the folder holding the dropped loose files.
    public var title: String
    public var presetName: String
    public var outputFormat: OutputFormat
    public var rows: [ItemRow]

    /// The header's label after the Preset badge: String(localized: "Original", bundle: .module, comment: "Image processing state or output format label."), "To JPEG" or "To PNG".
    public var outputFormatLabel: String {
        switch outputFormat {
        case .original: String(localized: "Original", bundle: .module, comment: "Image processing state or output format label.")
        case .jpeg: String(localized: "To JPEG", bundle: .module, comment: "Image processing state or output format label.")
        case .png: String(localized: "To PNG", bundle: .module, comment: "Image processing state or output format label.")
        }
    }
}

/// Counts and byte totals over one run: the Items since the Queue was last idle (spec §3.4, §3.5).
public struct RunSummary: Sendable, Hashable {
    public var images = 0
    public var finished = 0
    public var optimized = 0
    public var failed = 0
    public var skipped = 0
    public var cancelled = 0
    /// Non-image files ignored by the run's scans.
    public var ignored = 0
    /// Sizes of the Optimized Items only.
    public var originalBytes: Int64 = 0
    public var newBytes: Int64 = 0

    public init() {}

    public var savings: Savings { Savings(originalBytes: originalBytes, newBytes: newBytes) }

    public func count(_ filter: OutcomeFilter) -> Int {
        switch filter {
        case .failed: failed
        case .skipped: skipped
        case .cancelled: cancelled
        }
    }
}

/// The footer (spec §3.4): progress while running, the last run's totals when idle.
public struct FooterState: Sendable, Hashable {
    public var isRunning: Bool
    /// "37 / 128" while running, nil when idle.
    public var progressText: String?
    /// Running Savings while running, the last run's totals when idle; nil before any run.
    public var savingsText: String?
    var spokenLabel: String? = nil
}

/// The completion banner (spec §3.5).
public struct Banner: Sendable, Hashable {
    /// The full sentence, also posted as the notification.
    public var text: String
    /// The filter buttons to show, each with its count, in the order failed, skipped, cancelled.
    public var filters: [FilterButton]
    var spokenLabel: String? = nil

    public struct FilterButton: Sendable, Hashable, Identifiable {
        public var filter: OutcomeFilter
        public var title: String
        public var isOn: Bool
        public var id: OutcomeFilter { filter }
    }
}

/// Pure functions from Core values to the strings the views show. 5.6 and 5.7 own the wording.
public enum Presentation {
    public static func row(for item: Item) -> ItemRow {
        var row = ItemRow(
            id: item.id, name: item.source.lastPathComponent, folderPath: folderPath(of: item),
            stateText: "", isProcessing: false, sizesText: nil, savingsText: nil, isGrowth: false,
            detail: nil, openURL: nil)
        switch item.state {
        case .waiting:
            row.stateText = String(localized: "Waiting", bundle: .module, comment: "Image processing state shown in the result list.")
        case .processing:
            row.stateText = String(localized: "Processing", bundle: .module, comment: "Image processing state shown in the result list.")
            row.isProcessing = true
        case .finished(.optimized(let savings, let notes, let output)):
            row.stateText = String(localized: "Optimized", bundle: .module, comment: "Image processing state shown in the result list.")
            row.openURL = output
            let outputExtension = output.pathExtension
            if !outputExtension.isEmpty,
               outputExtension.lowercased() != item.source.pathExtension.lowercased() {
                row.convertedExtension = "." + outputExtension
            }
            row.sizesText = String(localized: "\(size(savings.originalBytes)) → \(size(savings.newBytes))", bundle: .module, comment: "Original file size followed by optimized size; both placeholders are formatted byte sizes.")
            row.savingsText = percentText(savings)
            row.isGrowth = savings.bytes < 0 && roundedPercent(savings) > 0
            row.isReduction = savings.bytes > 0 && roundedPercent(savings) > 0
            row.detail = notesText(notes)
        case .finished(.skipped(let reason, let notes, let output)):
            row.stateText = String(localized: "Skipped", bundle: .module, comment: "Image processing state shown in the result list.")
            row.issueText = row.stateText
            row.openURL = output ?? item.source
            row.detail = notes.reduce(reason.message) { joined($0, $1.message) }
        case .finished(.failed(let reason)):
            row.stateText = String(localized: "Failed", bundle: .module, comment: "Image processing state shown in the result list.")
            row.issueText = row.stateText
            row.detail = reason.message
        case .finished(.cancelled):
            row.stateText = String(localized: "Cancelled", bundle: .module, comment: "Image processing state shown in the result list.")
            row.issueText = row.stateText
        }
        row.spokenLabel = AccessibilityText.row(item: item, state: row.stateText, folderPath: row.folderPath)
        if row.convertedExtension != nil, let output = row.openURL, let speech = row.spokenLabel {
            row.spokenLabel = AccessibilityText.joined(speech, output.lastPathComponent)
        }
        return row
    }

    static func folderPath(of item: Item) -> String? {
        guard let root = item.droppedRoot else { return nil }
        let rootPath = root.standardizedFileURL.pathComponents
        let folder = item.source.standardizedFileURL.deletingLastPathComponent().pathComponents
        guard folder.starts(with: rootPath) else { return root.lastPathComponent }
        return ([root.lastPathComponent] + folder.dropFirst(rootPath.count)).joined(separator: "/")
    }

    /// The header path of a drop: its dropped folder, else the folder of its first file, with ~ for home.
    public static func sectionTitle(of item: Item?) -> String {
        guard let item else { return "" }
        let folder = item.droppedRoot ?? item.source.deletingLastPathComponent()
        return (folder.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// The subfolder below the section's dropped folder ("Day 1"), or nil when the file sits in it.
    static func subfolder(of item: Item) -> String? {
        guard let path = folderPath(of: item), let slash = path.firstIndex(of: "/") else { return nil }
        return String(path[path.index(after: slash)...])
    }

    static func notesText(_ notes: [Note]) -> String? {
        notes.map(\.message).reduce(nil as String?) { result, note in
            result.map { joined($0, note) } ?? note
        }
    }

    public static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "−62%" saved, "+18%" growth, "0%" when it rounds to nothing, in the region's percent style.
    public static func percentText(_ savings: Savings, locale: Locale = .current) -> String {
        let percent = roundedPercent(savings)
        if percent == 0 { return self.percent(0, locale: locale) }
        return self.percent(savings.bytes < 0 ? percent : -percent, signed: true, locale: locale)
    }

    /// A whole percentage in the region's style, such as "62%", or "%62" in Turkey.
    static func percent(_ whole: Int, signed: Bool = false, locale: Locale = .current) -> String {
        let style = FloatingPointFormatStyle<Double>.Percent(locale: locale).precision(.fractionLength(0))
        let value = Double(whole) / 100
        return signed ? value.formatted(style.sign(strategy: .always())) : value.formatted(style)
    }

    static func roundedPercent(_ savings: Savings) -> Int {
        Int(abs(savings.percent).rounded())
    }
}
