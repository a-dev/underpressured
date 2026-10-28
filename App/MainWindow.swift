import UnderpressuredApplication
import AppModel
import SwiftUI
import UnderpressuredCore

/// The single main window (spec §3): header, the empty state or the Item list, then the footer (or the banner in its place).
struct MainWindow: View {
    @Bindable var model: AppModel
    @Environment(\.undoManager) private var undoManager
    @State private var isTargeted = false
    @State private var showingIntakeFailures = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider()
            ToolbarRow(model: model)
            Divider()
            if model.isEmpty {
                EmptyStateView(isTargeted: isTargeted) { showOpenPanel(model: model) }
            } else {
                ItemListView(model: model)
            }
            Divider()
            if !model.intakeFailures.isEmpty {
                HStack {
                    Button("Some paths could not be read") { showingIntakeFailures = true }
                        .popover(isPresented: $showingIntakeFailures) {
                            IntakeFailureDetails(failures: model.intakeFailures)
                        }
                    Spacer()
                    Button("Dismiss") { model.dismissIntakeFailures() }
                }.padding(8)
                Divider()
            }
            // One footer slot: progress while running, the completion banner once the run ends.
            if let banner = model.banner, !model.isRunning {
                BannerView(banner: banner, toggle: model.toggleFilter)
            } else {
                FooterView(model: model)
            }
        }
        .environment(\.layoutDirection, AppLocalization.layoutDirection)
        .background(PresetUndoWindow(model: model, manager: undoManager).frame(width: 0, height: 0))
        .frame(minWidth: 560, minHeight: 360)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.open(urls) }
            return true
        } isTargeted: {
            isTargeted = $0
        }
    }
}

/// Spec §3.1: Preset badges, +, "…".
struct HeaderView: View {
    @Bindable var model: AppModel

    var body: some View {
        PresetBar(model: model)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

/// Always shown: destination choices on the left, Clear on the right.
struct ToolbarRow: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            DestinationControls(model: model)
            Spacer(minLength: 8)
            Button("Clear") { model.clear() }
                .fixedSize()
                .disabled(!model.canClear)
                .accessibilityIdentifier("clear-history")
                .accessibilityLabel(AccessibilityText.clearList)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct IntakeFailureDetails: View {
    let failures: [ScanFailure]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(failures, id: \.self) { failure in
                    VStack(alignment: .leading) {
                        Text(verbatim: failure.url.path).textSelection(.enabled)
                        Text(failure.reason.message).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(width: 400)
        .frame(maxHeight: 240)
        .fixedSize(horizontal: false, vertical: true)
    }
}
