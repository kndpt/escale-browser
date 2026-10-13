import SwiftUI

// ⌘L's parameters, drawn under the field in place of suggestions
// (Query.swift). A row reads as the address does, key then value, with a
// switch before it rather than a delete: turned off, it stays where it was,
// faded, ready to come back. The value is decoded to be read; the field above
// keeps the address as written, and selects a row's value when it is walked
// to, so typing there changes it.
//
// Tracking parameters come last, folded under one heading with the one
// action they usually need. The selected row says what Return does, as every
// Bearings row does; Space is on the switch's help, for the keyboard.
struct Parameters: View {
    @ObservedObject var input: Field
    let maxHeight: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if let query = input.query {
            let tracking = query.parameters.indices.filter { query.parameters[$0].tracking }
            let rows = input.shownParameters.count + (tracking.isEmpty ? 0 : 1)
            ScrollViewReader { scroll in
                ScrollView {
                    // Lazy: 4096 bytes can hold a couple of thousand parameters.
                    LazyVStack(spacing: 0) {
                        ForEach(input.shownParameters.filter { !query.parameters[$0].tracking }, id: \.self) { index in
                            row(query.parameters[index], at: index)
                        }
                        if !tracking.isEmpty {
                            heading(count: tracking.count)
                            if input.trackingShown {
                                ForEach(tracking, id: \.self) { index in
                                    row(query.parameters[index], at: index)
                                }
                            }
                        }
                    }
                    .padding(metrics.length(Metrics.searchGap))
                }
                .frame(height: min(CGFloat(rows) * metrics.length(Metrics.searchRowHeight)
                                   + metrics.length(Metrics.searchGap * 2), maxHeight))
                .onChange(of: input.parameter) { _, index in
                    if let index { scroll.scrollTo(index) }
                }
            }
        }
    }

    private func row(_ parameter: Query.Parameter, at index: Int) -> some View {
        Row(parameter: parameter, picked: input.parameter == index,
            toggle: { input.toggle(index) }, pick: { input.pick(index) })
            .id(index)
    }

    private func heading(count: Int) -> some View {
        HStack(spacing: metrics.length(Metrics.searchGap)) {
            Image(systemName: "chevron.right")
                .font(.system(size: metrics.length(Metrics.searchDetail), weight: .semibold))
                .rotationEffect(.degrees(input.trackingShown ? 90 : 0))
            Text("Tracking · \(count)")
                .font(.system(size: metrics.length(Metrics.searchDetail + 1)))
            Spacer(minLength: 0)
            Pill("Remove") { withAnimation(Motion.arrival) { input.removeTracking() } }
                .environment(\.cardDensity, .settings)
                .help("Remove tracking parameters from the address")
        }
        .foregroundStyle(Palette.muted)
        .padding(.horizontal, metrics.length(Metrics.searchInset))
        .frame(height: metrics.length(Metrics.searchRowHeight))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.arrival) { input.trackingShown.toggle() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tracking parameters, \(count)")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { input.trackingShown.toggle() }
    }

    private struct Row: View {
        let parameter: Query.Parameter
        let picked: Bool
        let toggle: () -> Void
        let pick: () -> Void
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @State private var hovering = false

        var body: some View {
            HStack(spacing: metrics.length(Metrics.searchInset)) {
                Switch(on: Binding(get: { parameter.on }, set: { _ in toggle() }))
                    .environment(\.cardDensity, .settings)
                    .help(parameter.on ? "Turn off · Space" : "Turn on · Space")
                Text(parameter.name)
                    .font(.system(size: metrics.length(Metrics.searchFont - 1), design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .strikethrough(!parameter.on)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: metrics.length(Metrics.queryKey), alignment: .leading)
                    .opacity(parameter.on ? 1 : 0.4)
                value
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .opacity(parameter.on ? 1 : 0.4)
                Spacer(minLength: 0)
                if let kind = parameter.kind {
                    Text(kind)
                        .font(.system(size: metrics.length(Metrics.searchDetail), weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, metrics.length(Metrics.searchGap))
                        .padding(.vertical, metrics.length(Metrics.searchBadgeInset))
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.searchGap)))
                        .fixedSize()
                }
                if picked {
                    HStack(spacing: metrics.length(Metrics.searchGap)) {
                        Image(systemName: "return").accessibilityHidden(true)
                        Text("Load")
                    }
                    .font(.system(size: metrics.length(Metrics.searchDetail)))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                }
            }
            .padding(.horizontal, metrics.length(Metrics.searchInset))
            .frame(height: metrics.length(Metrics.searchRowHeight))
            .background {
                if picked {
                    Chosen(radius: metrics.length(Metrics.searchRowRadius))
                } else if hovering {
                    RoundedRectangle(cornerRadius: metrics.length(Metrics.searchRowRadius)).fill(Palette.hover)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: pick)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
            .animation(Motion.settle, value: parameter.on)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(parameter.name): \(parameter.text)")
            .accessibilityValue(parameter.on ? "On" : "Off")
            .accessibilityAddTraits(picked ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(named: parameter.on ? "Turn off" : "Turn on", toggle)
        }

        /// A bare key has no value; an empty one says so.
        @ViewBuilder private var value: some View {
            if parameter.value == nil {
                EmptyView()
            } else if parameter.text.isEmpty {
                Text("empty")
                    .font(.system(size: metrics.length(Metrics.searchFont)))
                    .foregroundStyle(Palette.faint)
            } else {
                Text(parameter.text)
                    .font(.system(size: metrics.length(Metrics.searchFont)))
                    .foregroundStyle(Palette.ink)
            }
        }
    }
}
