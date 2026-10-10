import SwiftUI

/// Everywhere you have been, and everything you have kept. Two lists in the
/// same white-and-hairline panel as the rest, and in both cases the point is
/// as much being able to remove a line as to read one. Both walk with the
/// keyboard (Walk.swift).

enum When {
    private static let ago: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func said(_ date: Date) -> String {
        ago.localizedString(for: date, relativeTo: Date())
    }

    private static let hour: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let plain: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    /// The time of day. Once a list is grouped by day, that is all a row needs.
    static func clock(_ date: Date) -> String { hour.string(from: date) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return plain.string(from: date)
    }
}

/// What History's search holds. Every key changes it, so it has an owner of
/// its own, as the address field does (Field.swift): in `Browser`, each key
/// drew the whole window again, every tab included.
@MainActor
final class Recall: ObservableObject {
    @Published var hunt = ""
}

struct HistoryPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var recall: Recall

    @FocusState private var hunting: Bool
    @State private var days: [Day] = []
    @State private var count = 0
    @State private var clearing = false
    /// The line Return opens: the top one until the arrows move it.
    @State private var chosen: History.Trace.ID?
    /// The arrows have moved it since the last keystroke in the field: until
    /// the next one, ⌫ takes the line off rather than a letter.
    @State private var walked = false

    var body: some View {
        Plate("History", width: 600, close: { browser.recalling = false }) {
            VStack(alignment: .leading, spacing: 14) {
                Hunt(text: $recall.hunt, prompt: "Search everywhere you have been", focus: $hunting)
                    .walking(move: move, open: { apart in traces.first { $0.id == chosen }.map { go($0, apart: apart) } },
                             remove: walked ? { traces.first { $0.id == chosen }.map(forget) } : nil,
                             while: { !browser.tuning })

                if days.isEmpty {
                    Card { Nothing(recall.hunt.isEmpty ? "Nothing yet." : "Nothing matches.") }
                } else {
                    ScrollViewReader { list in
                        ScrollView(showsIndicators: false) {
                            // Lazy and flat, a line at a time: only what is in
                            // view is built. Each day as one Card built all its
                            // lines, 1,800 of them at the bound, and opening the
                            // panel took two seconds.
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(days) { day in
                                    Caption(day.title)
                                        .padding(.top, day.id == days.first?.id ? 0 : 14)
                                        .padding(.bottom, 6)
                                    ForEach(day.traces) { trace in
                                        Slice(top: trace.id == day.traces.first?.id,
                                              bottom: trace.id == day.traces.last?.id) {
                                            Row(
                                                trace: trace,
                                                chosen: trace.id == chosen,
                                                go: { go(trace, apart: false) },
                                                forget: { forget(trace) }
                                            )
                                        }
                                    }
                                }
                            }
                            .padding(.bottom, 2)
                        }
                        .frame(maxHeight: 420)
                        .onChange(of: chosen) { _, id in if let id { list.scrollTo(id) } }
                    }
                }
            }
        } foot: {
            if clearing {
                sweeps
            } else {
                HStack {
                    Text(count == 1 ? "1 page" : "\(count) pages")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                    Spacer()
                    Pill("Clear…") { withAnimation(Motion.settle) { clearing = true } }
                }
            }
        }
        .animation(Motion.settle, value: clearing)
        .onAppear(perform: start)
        // Shown again before its closing has finished, the panel is the same
        // view, and nothing appears.
        .onChange(of: browser.recalling) { _, open in if open { start() } }
        .onChange(of: recall.hunt) { _, _ in top() }
    }

    private func start() {
        hunting = true
        top()
    }

    /// The list read again, the selection back on its top line.
    private func top() {
        refresh()
        chosen = traces.first?.id
        walked = false
    }

    /// Every line, top to bottom, across the days.
    private var traces: [History.Trace] { days.flatMap(\.traces) }

    private func move(_ by: Int) {
        let all = traces
        chosen = Walk.step(all.map(\.id), from: chosen, by: by)
        walked = true
        if let trace = all.first(where: { $0.id == chosen }) { Walk.say(trace.title.isEmpty ? trace.key : trace.title) }
    }

    /// Into the tab you are on, as a click does; `apart`, ⌘Return, into a new one.
    private func go(_ trace: History.Trace, apart: Bool) {
        browser.recalling = false
        if apart { browser.open(trace.url, foreground: true, from: browser.active) } else { browser.active?.go(to: trace.url) }
    }

    /// Off the list, the selection passed to the line that takes its place.
    private func forget(_ trace: History.Trace) {
        let next = trace.id == chosen ? Walk.after(traces.map(\.id), removing: trace.id) : chosen
        browser.forgetHistory(trace)
        refresh()
        chosen = next
    }

    /// Three separate things, worded so nobody has to guess which one signs
    /// them out of their bank.
    private var sweeps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Card {
                Line("History", "Everywhere you have been") {
                    Pill("Clear") {
                        browser.clearHistory()
                        refresh()
                        withAnimation(Motion.settle) { clearing = false }
                    }
                }
                Rule()
                Line("Cookies and sign-ins", "Signs you out of every site") {
                    Pill("Sign out of everything") { browser.clearSites() }
                }
                Rule()
                Line("Cache", "Only what was fetched to draw pages") {
                    Pill("Clear") { browser.clearCache() }
                }
            }
            HStack {
                Spacer()
                Pill("Back") { withAnimation(Motion.settle) { clearing = false } }
            }
        }
        .transition(.opacity)
    }

    /// One day of the list. Worked out when the history is read, not in
    /// `body`: the panel is drawn again whenever anything in the browser
    /// changes, and grouping and sorting the whole history each time was
    /// work for nothing.
    private struct Day: Identifiable {
        let id: Date
        let title: String
        var traces: [History.Trace]
    }

    private func refresh() {
        let traces = browser.history.everything(matching: recall.hunt)
        let calendar = Calendar.current
        // Newest first already, so the days come in order and each keeps
        // its lines in theirs.
        var made: [Day] = []
        for trace in traces {
            let day = calendar.startOfDay(for: trace.last)
            if made.last?.id == day {
                made[made.count - 1].traces.append(trace)
            } else {
                made.append(Day(id: day, title: When.day(day), traces: [trace]))
            }
        }
        days = made
        count = traces.count
    }

    /// One line. A title, where it came from, and when — the three things you
    /// scan for, in the order you scan them.
    private struct Row: View {
        let trace: History.Trace
        let chosen: Bool
        let go: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                SiteMark(host: trace.url.host()?.lowercased() ?? "",
                     letter: trace.key.first.map { String($0).uppercased() } ?? "•", size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trace.title.isEmpty ? trace.key : trace.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(trace.key)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if hovering {
                    Quick("Remove", tint: Palette.danger, act: forget)
                } else {
                    Text(When.clock(trace.last))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(chosen ? Palette.wash : hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: go)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

struct DownloadsPanel: View {
    @ObservedObject var browser: Browser
    @ObservedObject var loot: Loot

    /// None until the arrows choose one: the panel opens with nothing chosen.
    @State private var chosen: Keep.ID?

    var body: some View {
        Plate("Downloads", width: 560, close: { browser.hoarding = false }) {
            if loot.kept.isEmpty {
                Card { Nothing("Nothing downloaded yet.") }
            } else {
                ScrollViewReader { list in
                    ScrollView(showsIndicators: false) {
                        Card {
                            ForEach(Array(loot.kept.enumerated()), id: \.element.id) { index, keep in
                                if index > 0 { Rule() }
                                Row(
                                    keep: keep,
                                    chosen: keep.id == chosen,
                                    open: { loot.open(keep) },
                                    reveal: { loot.reveal(keep) },
                                    forget: { forget(keep) }
                                )
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: chosen) { _, id in if let id { list.scrollTo(id) } }
                }
                // A file is not a page: ⌘Return shows it in the Finder,
                // where a tab would download a copy of what it can't show.
                .walking(move: move, open: { apart in
                    guard let keep = loot.kept.first(where: { $0.id == chosen }), keep.stillThere else { return }
                    if apart { loot.reveal(keep) } else { loot.open(keep) }
                }, remove: { loot.kept.first { $0.id == chosen }.map(forget) }, while: { !browser.tuning })
                // As History: shown again before it has gone, it keeps its state.
                .onChange(of: browser.hoarding) { _, open in if open { chosen = nil } }
            }
        } foot: {
            HStack {
                Text(loot.kept.isEmpty ? "Files land in \(browser.downloadsFolder.lastPathComponent)"
                     : "Clearing the list leaves the files where they are")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                Spacer()
                if !loot.kept.isEmpty {
                    Pill("Clear list") { loot.forgetAll() }
                }
            }
        }
    }

    private func move(_ by: Int) {
        chosen = Walk.step(loot.kept.map(\.id), from: chosen, by: by)
        if let keep = loot.kept.first(where: { $0.id == chosen }) { Walk.say(keep.name) }
    }

    /// Off the list only; the file stays where it is.
    private func forget(_ keep: Keep) {
        let next = keep.id == chosen ? Walk.after(loot.kept.map(\.id), removing: keep.id) : chosen
        loot.forget(keep)
        chosen = next
    }

    private struct Row: View {
        let keep: Keep
        let chosen: Bool
        let open: () -> Void
        let reveal: () -> Void
        let forget: () -> Void

        @State private var hovering = false

        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: keep.stillThere ? "doc" : "doc.badge.ellipsis")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(keep.stillThere ? Palette.muted : Palette.faint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(keep.name)
                        .font(.system(size: 13))
                        .foregroundStyle(keep.stillThere ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(keep.from.isEmpty ? When.said(keep.date) : "\(keep.from) · \(When.said(keep.date))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    if keep.stillThere { Quick("Show in Finder", act: reveal) }
                    Quick("Remove", tint: Palette.danger, act: forget)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(chosen ? Palette.wash : hovering ? Palette.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture { if keep.stillThere { open() } }
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}
