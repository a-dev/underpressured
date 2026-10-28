import AppModel
import SwiftUI

/// The completion banner with its filter buttons (spec §3.5).
struct BannerView: View {
    let banner: Banner
    let toggle: (OutcomeFilter) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summary.fixedSize()
                Spacer(minLength: 8)
                HStack(spacing: 8) { filters }.fixedSize()
            }
            VStack(alignment: .leading, spacing: 8) {
                summary.fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { filters }.fixedSize()
                    VStack(alignment: .leading, spacing: 8) { filters }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var summary: some View {
        Text(banner.text)
            .accessibilityLabel(banner.accessibilityLabel)
    }

    private var filters: some View {
        ForEach(banner.filters) { button in
            Button { toggle(button.filter) } label: {
                HStack(spacing: 4) {
                    if button.isOn {
                        Image(systemName: "checkmark").accessibilityHidden(true)
                    }
                    Text(button.title)
                }
            }
                .buttonStyle(.bordered)
                .tint(button.isOn ? .accentColor : nil)
                .overlay {
                    // Not colour alone: the active filter also gets an outline under Increase Contrast.
                    if button.isOn && contrast == .increased {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(.primary, lineWidth: 2)
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("outcome-filter-\(button.filter)")
                .accessibilityLabel(AccessibilityText.filterButton(title: button.title))
                .accessibilityValue(AccessibilityText.filterButtonValue(isOn: button.isOn) ?? "")
                .accessibilityAddTraits(button.isOn ? .isSelected : [])
        }
    }
}
