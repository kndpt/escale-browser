// Import choices use a compact labelled field and a custom SwiftUI list in a
// native popover. Only the selected row has a background; opening the list
// does not push the import actions down. Profile lists remain bounded.
import SwiftUI

struct MigrationField<Value: Hashable>: View {
    let title: String
    let options: [(Value, String)]
    @Binding var selection: Value
    var detail: (Value) -> String? = { _ in nil }
    var explanation: (Value) -> String = { _ in "" }
    var available: (Value) -> Bool = { _ in true }
    /// A symbol before a name, for choices known by an icon (a Space).
    var symbol: (Value) -> String? = { _ in nil }
    /// The closed field's height, lower beside Settings' denser fields.
    var height = Metrics.migrationChoiceHeight
    /// Off inside a card that already says what the field is for.
    var showsTitle = true
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var expanded = false

    var body: some View {
        HStack(spacing: metrics.length(Metrics.arrivalDetailGap)) {
            if showsTitle {
                Text(title).foregroundStyle(Palette.muted)
                    .frame(width: metrics.length(Metrics.migrationLabelWidth), alignment: .leading)
            }
            Button { expanded.toggle() } label: {
                HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                    if let symbol = symbol(selection) {
                        Image(systemName: symbol).foregroundStyle(Palette.muted)
                    }
                    Text(options.first { $0.0 == selection }?.1 ?? "Choose…")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: metrics.length(Metrics.arrivalRowGap))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: metrics.length(Metrics.arrivalSmall)))
                        .foregroundStyle(Palette.muted)
                }
                .padding(.horizontal, metrics.length(Metrics.arrivalDetailGap))
                .frame(height: metrics.length(height))
                .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius)))
                .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius)).strokeBorder(Palette.hairline))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "Choose")
            .popover(isPresented: $expanded) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(options, id: \.0) { value, name in
                            HStack(spacing: metrics.length(Metrics.arrivalLine)) {
                                Button {
                                    selection = value
                                    expanded = false
                                } label: {
                                    HStack(spacing: metrics.length(Metrics.arrivalRowGap)) {
                                        Image(systemName: "checkmark")
                                            .opacity(selection == value ? 1 : 0)
                                        if let symbol = symbol(value) {
                                            Image(systemName: symbol).foregroundStyle(Palette.muted)
                                        }
                                        Text(name).lineLimit(1).truncationMode(.middle)
                                        Spacer(minLength: metrics.length(Metrics.arrivalRowGap))
                                        if let detail = detail(value) {
                                            Text(detail).font(.system(size: metrics.length(Metrics.arrivalSmall)))
                                                .foregroundStyle(Palette.muted)
                                        }
                                    }
                                    .padding(.horizontal, metrics.length(Metrics.arrivalDetailGap))
                                    .frame(height: metrics.length(Metrics.migrationChoiceHeight))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!available(value))
                                .opacity(available(value) ? 1 : 0.45)
                                .accessibilityHint(explanation(value))
                                .accessibilityAddTraits(selection == value ? .isSelected : [])
                                if !available(value) {
                                    InfoTip(label: "Why \(name) is unavailable", explanation: explanation(value))
                                }
                            }
                            .background(selection == value ? Palette.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: metrics.length(Metrics.arrivalButtonRadius)))
                        }
                    }
                    .padding(metrics.length(Metrics.migrationChoiceInset))
                }
                .frame(width: metrics.length(Metrics.migrationChoiceWidth),
                       height: metrics.length(min(Metrics.migrationListHeight,
                                                  CGFloat(options.count) * Metrics.migrationChoiceHeight + 2 * Metrics.migrationChoiceInset)))
                .font(.system(size: metrics.length(Metrics.arrivalText)))
                .foregroundStyle(Palette.ink)
                .popoverGround()
            }
        }
    }
}
