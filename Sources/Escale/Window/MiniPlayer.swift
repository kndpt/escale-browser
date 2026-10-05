// The sidebar keeps one compact control surface for background audio, with a
// source chooser when several tabs play. Playback owns the window's source list;
// each Tab owns its Media reader. The view observes those small owners directly.
// Folding the column hides the surface without stopping playback; unfolding
// restores it. Floating video retains its existing controls and is omitted here.
// Hover belongs to the entire card; an open source chooser holds it expanded
// so crossing from playback controls into the chooser cannot move its anchor.
// VoiceOver and keyboard-only use never hover, and a control that is not drawn
// is neither spoken nor focusable, so for them the card stays expanded.
// A meeting's card also has its microphone, pressed through the page's own
// button (Meeting.swift), and lasts only as long as the meeting: once left, a
// page may go on playing a sound of its own, which WebKit still counts. Its
// page is asked once a second, only while the card is shown.
import SwiftUI

@MainActor
final class Playback: ObservableObject {
    @Published private(set) var sources: [Tab] = []
    @Published var selected: UUID?
    @Published var active: UUID? {
        didSet { if active != oldValue { minimized = nil } }
    }
    // Explicit reduction keeps even the active source visible until navigation
    // back to a source, without switching tabs just to expose its controls.
    @Published var minimized: UUID?
    @Published var floating: UUID?

    var visible: [Tab] { sources.filter { ($0.id != active || $0.id == minimized) && $0.id != floating && !$0.media.dismissed } }
    var source: Tab? { visible.first { $0.id == selected } ?? visible.first }

    func update(_ tab: Tab) {
        if let minimized, !sources.contains(where: { $0.id == minimized && $0.media.state != nil }) { self.minimized = nil }
        sources.removeAll { $0.media.state == nil || $0.built == nil }
        if tab.media.state != nil, tab.built != nil, !sources.contains(where: { $0.id == tab.id }) {
            sources.append(tab)
        }
        // Media's metadata changes do not pass through Browser's publisher.
        objectWillChange.send()
    }
}

extension Browser {
    func returnToMedia(_ id: UUID) {
        guard let tab = (tabs + parkedTabs).first(where: { $0.id == id }), tab.media.state != nil else { return }
        if tab.space != spaceID { switchSpace(to: tab.space) }
        guard tabs.contains(where: { $0 === tab }) else { return }
        playback.minimized = nil
        select(tab)
    }
}

struct MiniPlayer: View {
    @ObservedObject var playback: Playback
    let returnToSource: (UUID) -> Void
    let floatSource: (UUID) -> Void
    let spaceName: (UUID) -> String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var choosingSource = false

    private var expanded: Bool {
        Self.expands(hovered: hovered, choosingSource: choosingSource,
                     assistive: NSWorkspace.shared.isVoiceOverEnabled || NSApp.isFullKeyboardAccessEnabled)
    }

    /// Hover is the only way to reveal the full card, unless the person cannot hover.
    static func expands(hovered: Bool, choosingSource: Bool, assistive: Bool) -> Bool {
        hovered || choosingSource || assistive
    }

    var body: some View {
        if let tab = playback.source {
            VStack(spacing: metrics.length(Metrics.mediaGap)) {
                if playback.visible.count > 1 {
                    Button { choosingSource.toggle() } label: {
                        HStack {
                            Text("\(playback.visible.count) sources")
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .font(.system(size: metrics.length(Metrics.mediaCaption)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $choosingSource) { sourceChoices }
                }
                MediaFace(tab: tab, media: tab.media, expanded: expanded, returnToSource: { returnToSource(tab.id) },
                          floatSource: { floatSource(tab.id) })
                    .id(tab.id)
            }
            .foregroundStyle(Palette.ink)
            .padding(metrics.length(Metrics.mediaInset))
            .glass(.chip, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.mediaRadius)))
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(reduceMotion ? nil : Motion.arrival) { hovered = inside }
            }
            .animation(reduceMotion ? nil : Motion.arrival, value: expanded)
            .onChange(of: playback.visible.count) { _, count in
                if count < 2 { choosingSource = false }
            }
            .onDisappear { hovered = false; choosingSource = false }
            .padding(.bottom, metrics.length(Metrics.mediaGap))
        }
    }

    private var sourceChoices: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(playback.visible) { source in
                    Button {
                        playback.selected = source.id
                        choosingSource = false
                    } label: {
                        HStack(spacing: metrics.length(Metrics.mediaGap)) {
                            Image(systemName: "checkmark")
                                .opacity(playback.source?.id == source.id ? 1 : 0)
                            Text(source.label + " · " + spaceName(source.space) + (source.shy ? " · Private" : ""))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, metrics.length(Metrics.mediaInset))
                        .frame(height: metrics.length(Metrics.mediaControl + Metrics.mediaGap))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(playback.source?.id == source.id ? Palette.selection : .clear,
                                in: RoundedRectangle(cornerRadius: metrics.length(Metrics.mediaRadius)))
                    .accessibilityAddTraits(playback.source?.id == source.id ? .isSelected : [])
                }
            }
            .padding(metrics.length(Metrics.mediaInset))
        }
        .frame(width: metrics.length(Metrics.mediaSourcesWidth),
               height: metrics.length(min(Metrics.mediaSourcesHeight,
                                          CGFloat(playback.visible.count) * (Metrics.mediaControl + Metrics.mediaGap) + 2 * Metrics.mediaInset)))
        .font(.system(size: metrics.length(Metrics.mediaCaption)))
        .foregroundStyle(Palette.ink)
        .popoverGround()
        .onExitCommand { choosingSource = false }
    }
}

private struct MediaFace: View {
    @ObservedObject var tab: Tab
    @ObservedObject var media: Media
    let expanded: Bool
    let returnToSource: () -> Void
    let floatSource: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    /// A meeting's microphone as its page shows it (`open`, `muted`), or nil.
    @State private var microphone: String?

    var body: some View {
        if let state = media.state {
            VStack(alignment: .leading, spacing: metrics.length(Metrics.mediaGap)) {
                HStack(spacing: metrics.length(Metrics.mediaGap)) {
                    Button(action: returnToSource) {
                        HStack(spacing: metrics.length(Metrics.mediaGap)) {
                            if let icon = tab.icon {
                                Image(nsImage: icon).resizable().scaledToFit()
                                    .frame(width: metrics.length(Metrics.mediaIcon), height: metrics.length(Metrics.mediaIcon))
                            } else { Image(systemName: "music.note") }
                            Text(tab.label).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain).help("Return to source tab")
                    .accessibilityLabel("Return to media source: " + tab.label)
                    // One trailing slot keeps the title stable while playback
                    // moves to the expanded transport row and Close replaces it.
                    Group {
                        if expanded { control("xmark", "Dismiss mini player") { media.dismiss() } }
                        else { transport(state) }
                    }
                    .frame(width: metrics.length(Metrics.mediaControl), height: metrics.length(Metrics.mediaControl))
                }
                if expanded {
                    VStack(alignment: .leading, spacing: metrics.length(Metrics.mediaGap)) {
                        HStack(spacing: metrics.length(Metrics.mediaGap)) {
                            if state.actions.contains("volume"), let volume = state.volume {
                                control("speaker.minus", "Lower media volume") { media.command("volume", value: max(0, volume - 0.1)) }
                                control("speaker.plus", "Raise media volume") { media.command("volume", value: min(1, volume + 0.1)) }
                            }
                            Spacer(minLength: 0)
                            if let microphone {
                                let muted = microphone == "muted"
                                control(muted ? "mic.slash.fill" : "mic.fill",
                                        muted ? "Unmute the microphone" : "Mute the microphone") { pressMicrophone() }
                            }
                            if state.actions.contains("previous") { control("backward.end.fill", "Previous track") { media.command("previous") } }
                            transport(state)
                            if state.actions.contains("next") { control("forward.end.fill", "Next track") { media.command("next") } }
                            if tab.liftable { control("pip.enter", "Picture in Picture", act: floatSource) }
                        }.foregroundStyle(Palette.muted)
                        if tab.shy { Text("Private").foregroundStyle(Palette.muted) }
                        if let error = media.error { Text(error).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                    .transition(.opacity)
                }
            }
            .font(.system(size: metrics.length(Metrics.mediaCaption)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Mini player")
            .task(id: Players.isCall(tab.address)) {
                guard Players.isCall(tab.address) else {
                    microphone = nil
                    return
                }
                // Two answers in a row that the meeting is over, not one: a
                // page rebuilding for a moment is still in its meeting.
                var over = 0
                while !Task.isCancelled {
                    let state = await meeting()
                    microphone = state?["mic"] as? String
                    over = state?["live"] as? Bool == false ? over + 1 : 0
                    if over >= 2 { return media.dismiss() }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    /// What the meeting's page says of itself, or nil when it cannot answer.
    private func meeting() async -> [String: Any]? {
        guard let web = tab.built else { return nil }
        return await withCheckedContinuation { done in
            web.evaluateJavaScript(Meeting.state) { found, _ in done.resume(returning: found as? [String: Any]) }
        }
    }

    private func pressMicrophone() {
        tab.built?.evaluateJavaScript(Meeting.press("microphone")) { _, _ in
            Task { @MainActor in microphone = await meeting()?["mic"] as? String }
        }
    }

    @ViewBuilder
    private func transport(_ state: MediaState) -> some View {
        if state.actions.contains("pause"), state.playing {
            control("pause.fill", "Pause media") { media.command("pause") }
        } else if state.actions.contains("play"), !state.playing {
            control("play.fill", "Resume media") { media.command("play") }
        }
    }

    private func control(_ icon: String, _ label: String, act: @escaping () -> Void) -> some View {
        Door(icon: icon, help: label, box: Metrics.mediaControl, glyph: Metrics.mediaGlyph, act: act)
            .accessibilityLabel(label)
            .disabled(media.busy && label != "Dismiss mini player")
    }
}
