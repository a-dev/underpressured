import AppModel
import SwiftUI

/// File intake, highlighted while dragging (spec §3.2). Clicking it opens the Open panel.
struct EmptyStateView: View {
    let isTargeted: Bool
    let open: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: open) {
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.largeTitle)
                Text("Choose files or drop images or folders").font(.title3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isTargeted ? Color.accentColor : (contrast == .increased ? .primary : .secondary))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.15) : .clear)
        .overlay {
            if isTargeted && contrast == .increased {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // The highlight switches instantly; nothing here animates, and Reduce Motion keeps it so.
        .transaction { if reduceMotion { $0.animation = nil } }
        .accessibilityHint(AccessibilityText.emptyStateHint)
    }
}
