import AppModel
import SwiftUI

/// Progress, running Savings and Cancel; totals when idle (spec §3.4).
struct FooterView: View {
    @Bindable var model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let footer = model.footer
        HStack {
            HStack {
                if showsIdleHint {
                    Text(Self.idleHint)
                        .foregroundStyle(contrast == .increased ? .primary : .secondary)
                }
                if let progress = footer.progressText {
                    Text(progress).monospacedDigit()
                }
                if let savings = footer.savingsText {
                    Text(savings).foregroundStyle(contrast == .increased ? .primary : .secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(footer.accessibilityLabel ?? (showsIdleHint ? Self.idleHint : ""))
            Spacer()
            if footer.isRunning {
                Button("Cancel") { Task { await model.cancel() } }
            }
        }
        .padding(8)
    }

    private static let idleHint = String(localized: "Choose a preset and where to save, then add files.", bundle: .main)
    /// Before the first drop the footer has no totals; the hint keeps it at its usual height.
    private var showsIdleHint: Bool {
        model.isEmpty && model.footer.progressText == nil && model.footer.savingsText == nil
    }
}
