import UnderpressuredApplication
import Foundation
import Observation
import UnderpressuredCore

/// Owns window state and derives view values from Queue events.
@MainActor
@Observable
public final class AppModel {
    // MARK: Settings (remembered across launches, §4.4)

    public var presets: PresetList { didSet { settingsChanged() } }
    /// The active Preset's Output Format (§5).
    public var outputFormat: OutputFormat {
        get { presets.active.outputFormat }
        set { setPresetOutputFormat(presets.active.id, newValue) }
    }
    public var destination: DestinationSettings { didSet { settingsChanged() } }

    /// The Preset whose popover is open, if any (the pen, **+**, Edit, ⌘,).
    public var editingPresetID: Preset.ID? { didSet { nameAtEditStart = editingPresetID.flatMap { presets.preset(id: $0)?.displayName } } }
    /// The edited Preset's name when its popover opened; an emptied name reverts to it (§4.3).
    @ObservationIgnored var nameAtEditStart: String?

    public var presetUndoRevision = 0
    public var presetFocusID: Preset.ID?
    @ObservationIgnored public weak var presetUndoManager: UndoManager?
    @ObservationIgnored var presetActivationRevision = 0
    @ObservationIgnored var presetEditingOperation: (name: String, before: PresetList)?

    // MARK: Item list

    /// Rows in drop order, filtered by `filter`.
    public var rows: [ItemRow] {
        entries.filter { filter?.matches($0.item.state) ?? true }.map { Presentation.row(for: $0.item) }
    }
    /// `rows` grouped by drop, in drop order; a drop with no matching rows is left out.
    public var sections: [ItemSection] {
        var sections: [ItemSection] = []
        for entry in entries where filter?.matches(entry.item.state) ?? true {
            var row = Presentation.row(for: entry.item)
            row.folderPath = Presentation.subfolder(of: entry.item)
            if sections.last?.id == entry.batch {
                sections[sections.count - 1].rows.append(row)
            } else {
                sections.append(ItemSection(
                    id: entry.batch, title: Presentation.sectionTitle(of: entry.item),
                    presetName: headerByBatch[entry.batch]?.presetName ?? "",
                    outputFormat: headerByBatch[entry.batch]?.outputFormat ?? .original, rows: [row]))
            }
        }
        return sections
    }

    /// Advances only when a nonempty batch enters the list, independently of filtering.
    public private(set) var intakeAdmissionRevision = 0
    /// Paths that could not be scanned; never counted as images or intentionally ignored files.
    public private(set) var intakeFailures: [ScanFailure] = []

    public func dismissIntakeFailures() { intakeFailures.removeAll() }

    /// The selected visible rows. File actions check availability when invoked.
    public var selection: Set<Item.ID> = []

    /// Selected, openable files that still exist, in list order.
    public func openableURLs(for selection: Set<Item.ID>) -> [URL] {
        entries.lazy.map(\.item).filter { selection.contains($0.id) }
            .compactMap { Presentation.row(for: $0).openURL }
            .filter(fileExists)
    }

    /// Whether any Item is Waiting or Processing, or a drop is still being scanned.
    public private(set) var isRunning = false
    /// The banner's filter; nil shows every row.
    public var filter: OutcomeFilter? {
        didSet { selection.formIntersection(rows.map(\.id)) }
    }
    /// Shown once the Queue drains, until the next run starts or the list is cleared.
    public var banner: Banner? {
        guard showsBanner, let summary = listSummary else { return nil }
        return Presentation.banner(summary, filter: filter)
    }
    /// The banner already states the Savings, so the footer leaves them out while it shows.
    public var footer: FooterState {
        Presentation.footer(showsBanner ? nil : runSummary, isRunning: isRunning)
    }
    public var isEmpty: Bool { entries.isEmpty }
    public var canClear: Bool { !isRunning && (!entries.isEmpty || !intakeFailures.isEmpty) }
    /// Items still Waiting or Processing: what quitting would cancel (§3.7).
    public var remainingCount: Int { unfinishedCount }

    // MARK: Private state

    private struct Entry {
        var item: Item
        var run: Int
        var batch: Batch.ID
    }

    private var entries: [Entry] = []
    private var indexByItem: [Item.ID: Int] = [:]
    private var headerByBatch: [Batch.ID: (presetName: String, outputFormat: OutputFormat)] = [:]
    private var currentRun = 0
    private var hasRun = false
    private var currentIgnoredCount = 0
    private var totalIgnoredCount = 0
    private var unfinishedCount = 0
    private var showsBanner = false
    var processingActivity: ProcessingSession.Activity { session.activity }
    var pendingScans: Int { processingActivity.pendingScans }
    private var askedForNotifications = false
    @ObservationIgnored private let session: ProcessingSession

    @ObservationIgnored private let settingsStore: any SettingsStore
    @ObservationIgnored private let notifier: any Notifier
    @ObservationIgnored private let sleepPreventer: any SleepPreventer
    @ObservationIgnored private let isFrontmost: @MainActor () -> Bool
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private var delayedFlush: Task<Void, Never>?
    /// Queue events wait here until the next throttled presentation flush (§7.7).
    @ObservationIgnored private let pending: PendingEvents
    /// How many times a flush changed the state: the test hook for the throttle.
    @ObservationIgnored private(set) var appliedUpdateCount = 0

    public convenience init(
        queue: Queue, intake: @escaping Intake,
        settingsStore: any SettingsStore = InMemorySettingsStore(),
        notifier: any Notifier = SilentNotifier(),
        sleepPreventer: any SleepPreventer = NoSleepPreventer(),
        isFrontmost: @escaping @MainActor () -> Bool = { true },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        folderAccess: any FolderAccess = UnrestrictedFolderAccess(),
        updateInterval: Duration = .milliseconds(100)
    ) {
        self.init(queue: queue, intake: intake, settingsStore: settingsStore,
                  notifier: notifier, sleepPreventer: sleepPreventer, isFrontmost: isFrontmost,
                  fileExists: fileExists, folderAccess: folderAccess, updateInterval: updateInterval,
                  progressTime: ContinuousProgressTime())
    }

    init(
        queue: Queue, intake: @escaping Intake,
        settingsStore: any SettingsStore = InMemorySettingsStore(),
        notifier: any Notifier = SilentNotifier(),
        sleepPreventer: any SleepPreventer = NoSleepPreventer(),
        isFrontmost: @escaping @MainActor () -> Bool = { true },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        folderAccess: any FolderAccess = UnrestrictedFolderAccess(),
        updateInterval: Duration = .milliseconds(100),
        progressTime: any ProgressTime
    ) {
        pending = PendingEvents(time: progressTime)
        session = ProcessingSession(queue: queue, intake: intake, folderAccess: folderAccess)
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.sleepPreventer = sleepPreventer
        self.isFrontmost = isFrontmost
        self.fileExists = fileExists
        let settings = settingsStore.load() ?? .initial
        presets = settings.presets
        destination = settings.destination
        session.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .runStarted:
                self.startRun()
                if !self.askedForNotifications {
                    self.askedForNotifications = true
                    self.notifier.requestPermission()
                }
            case .scanFailures(let failures):
                var known = Set(self.intakeFailures)
                for failure in failures where known.insert(failure).inserted {
                    self.intakeFailures.append(failure)
                }
            case .activity(let activity):
                // Completion must see all terminal queue events, regardless of the UI throttle.
                if !activity.isRunning { self.applyPending() }
                self.setRunning(activity.isRunning)
            case .queue(let event):
                switch self.pending.add(event, interval: updateInterval) {
                case .wait: break
                case .now:
                    self.delayedFlush?.cancel()
                    self.delayedFlush = nil
                    self.applyPending()
                case .after(let deadline):
                    self.delayedFlush?.cancel()
                    self.delayedFlush = Task { [weak self] in
                        do { try await progressTime.sleep(until: deadline) } catch { return }
                        guard !Task.isCancelled else { return }
                        self?.applyPending()
                    }
                }
            }
        }
    }

    isolated deinit { delayedFlush?.cancel() }

    public var settings: AppSettings {
        AppSettings(presets: presets, destination: destination)
    }

    // MARK: Intake

    /// Scan incoming URLs into one Batch with current settings. Ignore URLs without a usable Destination.
    public func open(_ urls: [URL]) async {
        await session.open(urls) { [self] in
            guard let destination = destination.destination else { return nil }
            var capturedPreset = presets.active
            capturedPreset.setName(capturedPreset.displayName)
            return ProcessingSession.Capture(preset: capturedPreset, outputFormat: outputFormat, destination: destination)
        }
    }

    /// Cancel (§7.6): invalidate pending intake and cancel the whole Queue.
    public func cancel() async {
        await session.cancel()
        applyPending()
    }

    /// Empties the list. Does nothing while the Queue runs (§3.3).
    public func clear() {
        guard canClear else { return }
        intakeFailures.removeAll()
        entries.removeAll()
        indexByItem.removeAll()
        headerByBatch.removeAll()
        selection.removeAll()
        filter = nil
        showsBanner = false
        currentIgnoredCount = 0
        totalIgnoredCount = 0
        unfinishedCount = 0
        currentRun = 0
        hasRun = false
    }

    /// Clicking a banner filter button: on, or off again if it's already on (§3.5).
    public func toggleFilter(_ kind: OutcomeFilter) {
        filter = filter == kind ? nil : kind
    }

    // MARK: Queue events

    /// Folds every waiting event into the state in one go, so the views redraw once per flush.
    func applyPending() {
        let events = pending.take()
        guard !events.isEmpty else { return }
        appliedUpdateCount += 1
        events.forEach(apply)
    }

    private func apply(_ event: QueueEvent) {
        switch event {
        case .batchAdded(let batch):
            if !batch.items.isEmpty { intakeAdmissionRevision += 1 }
            currentIgnoredCount += batch.ignoredCount
            totalIgnoredCount += batch.ignoredCount
            headerByBatch[batch.id] = (batch.presetName, batch.outputFormat)
            for item in batch.items {
                indexByItem[item.id] = entries.count
                entries.append(Entry(item: item, run: currentRun, batch: batch.id))
                if !item.state.isFinished { unfinishedCount += 1 }
            }
        case .itemChanged(_, let itemID, let state):
            if let index = indexByItem[itemID] {
                if !entries[index].item.state.isFinished, state.isFinished { unfinishedCount -= 1 }
                entries[index].item.state = state
            }
        case .idle:
            break
        }
    }

    /// A drop while idle starts a new run; drops during a run join it (§3.4, §3.5).
    private func startRun() {
        currentRun += 1
        currentIgnoredCount = 0
        hasRun = true
        showsBanner = false
        filter = nil
    }

    private func setRunning(_ running: Bool) {
        guard running != isRunning else { return }
        let wasRunning = isRunning
        isRunning = running
        sleepPreventer.setPreventing(
            running,
            reason: String(localized: "Optimizing images", bundle: .module, comment: "System-visible reason for preventing idle sleep during processing."))
        if wasRunning, !running { runFinished() }
    }

    private func runFinished() {
        guard let summary = runSummary else { return }
        showsBanner = true
        if !isFrontmost() {
            notifier.post(Presentation.banner(summary, filter: nil).text)
        }
    }

    /// The current run while running, or the last one when idle; nil before the first Batch.
    var runSummary: RunSummary? {
        guard hasRun else { return nil }
        return summary(of: entries.filter { $0.run == currentRun }, ignored: currentIgnoredCount)
    }

    /// Every row in the list, so the banner offers a filter for each outcome the list can show.
    var listSummary: RunSummary? {
        guard hasRun else { return nil }
        return summary(of: entries, ignored: totalIgnoredCount)
    }

    private func summary(of entries: [Entry], ignored: Int) -> RunSummary {
        var summary = RunSummary()
        summary.ignored = ignored
        for entry in entries {
            summary.images += 1
            guard case .finished(let outcome) = entry.item.state else { continue }
            summary.finished += 1
            switch outcome {
            case .optimized(let savings, _, _):
                summary.optimized += 1
                summary.originalBytes += savings.originalBytes
                summary.newBytes += savings.newBytes
            case .skipped: summary.skipped += 1
            case .failed: summary.failed += 1
            case .cancelled: summary.cancelled += 1
            }
        }
        return summary
    }

    private func settingsChanged() {
        settingsStore.save(settings)
    }

    /// Reserves intake admission immediately and invokes `action` once current work drains.
    /// The reservation remains held until released, including after the action runs.
    /// This is the app boundary's atomic handoff to an exclusive operation such as restart.
    public func reserveIdleOperation(_ action: @escaping @MainActor () -> Void) -> UUID? {
        let token = session.reserveIdleOperation { [weak self] in
            self?.applyPending()
            action()
        }
        applyPending()
        return token
    }

    public func releaseIdleOperation(_ id: UUID) {
        session.releaseIdleOperation(id)
    }

    /// Returns after application activity settles and presentation has consumed its events.
    func untilIdle() async {
        await session.untilIdle()
        applyPending()
    }
}
