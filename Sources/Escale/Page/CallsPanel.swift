// The API Calls tool of Developer mode (Developer.swift, Calls.swift). It
// lists the calls newest first, and says so above them, Fetch and XHR by
// default, and opens one in place: what was sent, the headers, then the
// response, read from WebKit when opened. ↑ and ↓ go to the newer and older
// call of the list as shown without going back to it, keeping the part
// looked at; the JSON tree keeps them while it has the keyboard, and ⌥↑ ⌥↓
// work from it too. The two arrows at the foot say so and do the same.
//
// Recording pauses and resumes from the toolbar without losing the list: a
// pause symbol while recording, a red record dot while paused, and the word
// Paused beside the order. The search field also looks in responses
// (CallSearch.swift): a call listed for its response says so with a short
// excerpt, and opens on the place in its tree or its text.
//
// Everything is drawn with Escale's own pieces (docs/DESIGN.md). Exchanged
// data is shown the way a developer reads it: JSON as a tree with one-line
// previews and light tints for keys, text and numbers, forms as pairs. Each
// block offers its copy button where the pointer is, not in a toolbar. A body
// WebKit cannot give is said to be unavailable, with its reason; an empty area
// never stands for one.
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The API Calls tool inside Developer mode (Developer.swift): the list,
/// or one call opened in its place.
struct CallsTool: View {
    @ObservedObject var calls: Calls
    let browser: Browser
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let id = calls.selected, let call = calls.list[id] {
                CallSheet(calls: calls, found: calls.found, call: call, browser: browser)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            } else {
                CallsList(calls: calls, found: calls.found, browser: browser)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Motion.settle, value: calls.selected)
    }
}

/// The opened call's options, at the end of its title line: what a
/// developer does with a request elsewhere, starting with a terminal.
struct CallMenu: View {
    @ObservedObject var calls: Calls
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if let id = calls.selected, let call = calls.list[id] {
            let missing = Curl.missing(call, calls.detail)
            Menu {
                Menu("Copy as") {
                    Button(missing.map { "cURL (\($0.lowercased()))" } ?? "cURL") {
                        if let detail = calls.detail { Clipboard.put(Curl.command(call, detail)) }
                    }
                    .disabled(missing != nil)
                }
            } label: {
                // A native menu draws its label as an image and drops
                // SwiftUI's rotation: the dots are turned once, here.
                Image(nsImage: Self.dots(metrics.length(11)))
                    .frame(width: metrics.length(26), height: metrics.length(26))
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Options")
            .accessibilityLabel("Call options")
        }
    }

    /// The ellipsis symbol stood upright, as a template image.
    private static func dots(_ size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let dots = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Options")?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let flat = dots.size
        let image = NSImage(size: NSSize(width: flat.height, height: flat.width), flipped: false) { rect in
            let turn = NSAffineTransform()
            turn.translateX(by: rect.width / 2, yBy: rect.height / 2)
            turn.rotate(byDegrees: 90)
            turn.translateX(by: -flat.width / 2, yBy: -flat.height / 2)
            turn.concat()
            dots.draw(in: NSRect(origin: .zero, size: flat))
            return true
        }
        image.isTemplate = true
        return image
    }
}

// MARK: - The list

private struct CallsList: View {
    @ObservedObject var calls: Calls
    @ObservedObject var found: CallSearch
    let browser: Browser
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @FocusState private var searching: Bool

    var body: some View {
        let shown = calls.shown
        let matches = found.current(calls.search)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: metrics.length(Metrics.callsGap)) {
                Segmented(options: [(CallList.Filter.api, "Fetch/XHR"), (.errors, "Errors"), (.all, "All")], selection: $calls.filter)
                Hunt(text: $calls.search, prompt: "Filter or search responses", focus: $searching)
                HStack(spacing: metrics.length(2)) {
                    RecordToggle(recording: calls.recording) { calls.record(!calls.recording) }
                        .disabled(!calls.collects)
                        .opacity(calls.collects ? 1 : 0.4)
                    Door(icon: "trash", help: "Clear the list") { calls.clear() }
                        .disabled(calls.list.count == 0)
                        .opacity(calls.list.count == 0 ? 0.4 : 1)
                        .accessibilityLabel("Clear the list")
                }
            }
            .padding(.horizontal, metrics.length(Metrics.callsInset))
            .padding(.top, metrics.length(Metrics.callsInset))
            .padding(.bottom, metrics.length(Metrics.callsGap))

            status
            order
            Rectangle().fill(Palette.hairline).frame(height: 1)

            if shown.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: metrics.length(1)) {
                        ForEach(shown) { call in
                            CallRow(call: call, wide: calls.filter != .api, match: matches[call.id]) { calls.select(call.id) }
                        }
                    }
                    .padding(metrics.length(6))
                }
            }
            if calls.list.dropped > 0 {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Text("The \(calls.list.dropped) oldest calls were let go; the latest \(CallList.limit) are kept.")
                    .font(.system(size: metrics.length(Metrics.callsSmall)))
                    .foregroundStyle(Palette.muted)
                    .padding(.horizontal, metrics.length(Metrics.callsInset))
                    .padding(.vertical, metrics.length(Metrics.callsGap))
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch calls.phase {
        case .connecting:
            HStack(spacing: metrics.length(Metrics.callsGap)) {
                MigrationSpinner()
                Text("Connecting to WebKit's network record…")
                    .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, metrics.length(Metrics.callsInset + 2))
            .padding(.bottom, metrics.length(Metrics.callsGap))
        case .stopped(let reason):
            Notice(symbol: "pause.circle", title: "Collection stopped", text: reason) {
                Pill("Resume", filled: true) {
                    if let tab = browser.active, tab.id == calls.tab { calls.start(tab, session: browser.inspection) }
                }
            }
            .padding(.horizontal, metrics.length(Metrics.callsInset))
            .padding(.bottom, metrics.length(Metrics.callsGap))
        default:
            EmptyView()
        }
    }

    /// Where new calls arrive, then what the list is doing: recording
    /// paused, a search in responses under way or not complete.
    private var order: some View {
        HStack(spacing: metrics.length(4)) {
            Image(systemName: "arrow.up")
                .font(.system(size: metrics.length(Metrics.callsSmall - 1), weight: .semibold))
            Text("Newest first")
            if calls.filter == .all { kinds }
            Spacer(minLength: metrics.length(6))
            searchState
            if !calls.recording {
                HStack(spacing: metrics.length(3)) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: metrics.length(Metrics.callsSmall - 2)))
                    Text("Paused")
                }
                .foregroundStyle(Palette.ink)
                .help("Recording is paused: calls made now are not listed. The red button resumes it.")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording paused")
            }
        }
        .font(.system(size: metrics.length(Metrics.callsSmall)))
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
        .padding(.leading, metrics.length(Metrics.callsInset + 2))
        .padding(.trailing, metrics.length(Metrics.callsInset))
        .padding(.bottom, metrics.length(6))
        .accessibilityElement(children: .contain)
    }

    /// Under All, one resource type or every one.
    private var kinds: some View {
        Menu {
            Picker("", selection: $calls.kind) {
                Text("Any type").tag(CallList.Kind?.none)
                ForEach(CallList.Kind.allCases) { Text($0.title).tag(Optional($0)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text("· " + (calls.kind?.title ?? "Any type"))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel("Resource type")
    }

    /// Said only when it matters: a search running, one that could not
    /// read every response in full, or none possible.
    @ViewBuilder private var searchState: some View {
        let typed = calls.search.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty {
            EmptyView()
        } else if CallSearch.wanted(typed).isEmpty {
            Text("Responses from \(CallSearch.shortest) characters")
        } else if let halted = found.halted {
            Text("Responses not searched").help(halted)
        } else if found.running || found.coverage == nil {
            Text("Searching responses…")
        } else if let coverage = found.coverage, coverage.missed > 0 {
            Text("\(coverage.missed) \(coverage.missed == 1 ? "response" : "responses") not fully searched")
                .help(coverage.words)
        }
    }

    /// The filter as the bar names it; nil when nothing is filtered out.
    private var narrowing: String? {
        switch calls.filter {
        case .api: return "Fetch/XHR"
        case .errors: return "Errors"
        case .all: return calls.kind?.title
        }
    }

    /// Which filter hides calls the search would otherwise list, if one does.
    private var hidden: String {
        guard let narrowing else { return "" }
        let others = calls.list.shown(.all, matching: calls.search, bodies: Set(found.current(calls.search).keys)).count
        guard others > 0 else { return "" }
        return " \(narrowing) hides " + (others == 1 ? "one other request." : "\(others) other requests.")
    }

    private var nothingYet: String {
        switch calls.filter {
        case .api: return "No Fetch or XHR calls yet"
        case .errors: return "No errors"
        case .all: return calls.kind.map { "No \($0.title.lowercased()) requests yet" } ?? "No requests yet"
        }
    }

    @ViewBuilder private var empty: some View {
        VStack(spacing: metrics.length(Metrics.callsGap)) {
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: metrics.length(18), weight: .light))
                .foregroundStyle(Palette.muted)
            if !calls.search.isEmpty {
                Text("No call matches “\(calls.search)”")
                    .font(.system(size: metrics.length(Metrics.callsText + 0.5), weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text((CallSearch.wanted(calls.search).isEmpty ? "Addresses, methods and statuses were searched."
                     : found.running || found.coverage == nil && found.halted == nil ? "Searching responses…"
                     : "In addresses, methods, statuses or responses.")
                     + hidden)
                    .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
            } else if !calls.recording {
                Text("Recording is paused")
                    .font(.system(size: metrics.length(Metrics.callsText + 0.5), weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text("Calls made now are not listed. The red button resumes recording.")
                    .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(nothingYet)
                    .font(.system(size: metrics.length(Metrics.callsText + 0.5), weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text((calls.filter == .errors ? "4xx and 5xx answers, failed and cancelled calls appear here."
                      : "Calls appear as the page makes them. Those made before the panel opened are not shown.")
                     + hidden)
                    .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if calls.phase == .collecting {
                    Pill("Reload Page") { browser.reload() }
                        .padding(.top, metrics.length(4))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, metrics.length(28))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CallRow: View {
    let call: Call
    /// Every kind of request is listed: its type is worth a word.
    let wide: Bool
    /// Listed for its response: where the search found the text.
    let match: CallSearch.Match?
    let open: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.callsRowRadius), style: .continuous)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: metrics.length(Metrics.callsGap)) {
                    MethodMark(method: call.method)
                        .frame(width: metrics.length(Metrics.callsMethod), alignment: .leading)
                    VStack(alignment: .leading, spacing: metrics.length(2)) {
                        Text(call.path)
                            .font(.system(size: metrics.length(Metrics.callsText)))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(([call.host] + (wide ? [call.type] : []) + [maker])
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: metrics.length(Metrics.callsSmall)))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: metrics.length(4))
                    VStack(alignment: .trailing, spacing: metrics.length(2)) {
                        StatusMark(call: call)
                        Text(facts)
                            .font(.system(size: metrics.length(Metrics.callsSmall)).monospacedDigit())
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)
                }
                // The whole width under the address, so the occurrence shows.
                if let match {
                    HStack(alignment: .firstTextBaseline, spacing: metrics.length(5)) {
                        Text("Response")
                            .font(.system(size: metrics.length(Metrics.callsSmall - 0.5), weight: .medium))
                            .foregroundStyle(Palette.muted)
                        Marked.excerpt(match)
                            .font(.system(size: metrics.length(Metrics.callsSmall), design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, metrics.length(Metrics.callsMethod + Metrics.callsGap))
                    .padding(.top, metrics.length(3))
                }
            }
            .padding(.horizontal, metrics.length(8))
            .padding(.vertical, metrics.length(6.5))
            .background(shape.fill(hovering ? Palette.hover : .clear))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .accessibilityLabel("\(call.method) \(call.path), \(StatusMark.words(call))"
                            + (match.map { ", response contains “\($0.hit)”: \($0.before)\($0.hit)\($0.after)" } ?? ""))
    }

    /// Only what differs from the page itself asking.
    private var maker: String {
        switch call.target {
        case "worker": return call.targetName.isEmpty ? "Worker" : "Worker · " + call.targetName
        case "service-worker": return "Service worker"
        default: return call.mainFrame == false ? "Frame" : ""
        }
    }

    private var facts: String {
        [call.duration.map(Call.milliseconds), call.size.map { Call.bytes($0) }].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The method, in a fixed face; a write is tinted so it stands out from reads.
private struct MethodMark: View {
    let method: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        Text(method)
            .font(.system(size: metrics.length(Metrics.callsSmall), weight: .semibold, design: .monospaced))
            .foregroundStyle(["GET", "HEAD", "OPTIONS"].contains(method) ? Palette.muted : Palette.codeKey)
            .lineLimit(1)
    }
}

/// A call's outcome in a word or a code, with a dot of its colour: the
/// word carries the meaning, the colour only helps the eye.
private struct StatusMark: View {
    let call: Call
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(spacing: metrics.length(4)) {
            Circle().fill(tint).frame(width: metrics.length(Metrics.callsDot), height: metrics.length(Metrics.callsDot))
            Text(Self.label(call))
                .font(.system(size: metrics.length(Metrics.callsMono), weight: .medium, design: .monospaced))
                .foregroundStyle(ink)
        }
        .fixedSize()
    }

    static func label(_ call: Call) -> String {
        switch call.state {
        case .loading: return "Pending"
        case .done(let status): return "\(status)"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .earlier: return "Earlier"
        }
    }

    static func words(_ call: Call) -> String {
        switch call.state {
        case .failed(let reason): return "failed: " + reason
        case .done(let status): return "status \(status)"
        default: return label(call).lowercased()
        }
    }

    private var tint: Color {
        switch call.state {
        case .done(let status) where status >= 500: return Palette.danger
        case .done(let status) where status >= 400: return Palette.unsafe
        case .done: return Palette.safe
        case .failed: return Palette.danger
        case .loading, .canceled, .earlier: return Palette.faint
        }
    }

    private var ink: Color {
        switch call.state {
        case .done(let status) where status >= 500: return Palette.danger
        case .done(let status) where status >= 400: return Palette.unsafe
        case .failed: return Palette.danger
        case .done: return Palette.ink
        default: return Palette.muted
        }
    }
}

// MARK: - One call

private struct CallSheet: View {
    @ObservedObject var calls: Calls
    @ObservedObject var found: CallSearch
    let call: Call
    let browser: Browser
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var part = Part.response
    @State private var copied = false
    /// The JSON tree has the keyboard and keeps the plain arrows.
    @State private var treeKeys = false

    enum Part: Hashable { case request, headers, response }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Segmented(options: [(Part.request, "Request"), (.headers, "Headers"), (.response, "Response")], selection: $part, wide: true)
                .padding(.horizontal, metrics.length(Metrics.callsInset))
                .padding(.bottom, metrics.length(Metrics.callsGap))
            Rectangle().fill(Palette.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: metrics.length(16)) {
                        switch part {
                        case .request: request
                        case .headers: headers
                        case .response: response(proxy)
                        }
                    }
                    .padding(metrics.length(Metrics.callsInset))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: call.id) { proxy.scrollTo(Self.top, anchor: .top) }
            }
            Rectangle().fill(Palette.hairline).frame(height: 1)
            foot
        }
        .background(StepKeys(tree: treeKeys) { calls.step($0) })
    }

    static let top = "top"

    private var header: some View {
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            HStack(spacing: metrics.length(2)) {
                Door(icon: "chevron.left", help: "All calls") { calls.select(nil) }
                    .accessibilityLabel("All calls")
                MethodMark(method: call.method)
                    .padding(.leading, metrics.length(2))
                Text(call.path)
                    .font(.system(size: metrics.length(Metrics.callsTitle - 0.5), weight: .medium))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(call.url)
                Spacer(minLength: metrics.length(4))
                CallMenu(calls: calls)
            }
            HStack(spacing: metrics.length(Metrics.callsGap)) {
                StatusMark(call: call)
                if case .done = call.state, !call.statusText.isEmpty {
                    Text(call.statusText).foregroundStyle(Palette.muted)
                }
                if let duration = call.duration { Text(Call.milliseconds(duration)).foregroundStyle(Palette.muted) }
                if let size = call.size { Text(Call.bytes(size)).foregroundStyle(Palette.muted) }
                Spacer(minLength: 0)
                Text(call.host).foregroundStyle(Palette.muted).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)).monospacedDigit())
            .padding(.leading, metrics.length(8))
            .padding(.trailing, metrics.length(4))
            if case .failed(let reason) = call.state {
                Text(reason)
                    .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                    .foregroundStyle(Palette.danger)
                    .padding(.leading, metrics.length(8))
            }
        }
        .padding(.leading, metrics.length(Metrics.callsInset - 6))
        .padding(.trailing, metrics.length(Metrics.callsInset - 4))
        .padding(.top, metrics.length(Metrics.callsInset - 4))
        .padding(.bottom, metrics.length(10))
    }

    // MARK: Request

    @ViewBuilder private var request: some View {
        Color.clear.frame(height: 0).id(Self.top)
        Block(title: "URL") {
            Copyable(text: call.url) { Mono(call.url) }
        }
        if let items = URLComponents(string: call.url)?.queryItems, !items.isEmpty {
            Block(title: "Query") {
                Pairs(items.prefix(100).map { CallDetail.Header(name: $0.name, value: $0.value ?? "") })
            }
        }
        Block(title: "Body") { sent }
        if let redirects = calls.detail?.redirects, !redirects.isEmpty {
            Block(title: "Redirects") {
                Pairs(redirects.map { CallDetail.Header(name: $0.status.map(String.init) ?? "—", value: $0.url) })
            }
        }
        Block(title: "Context") {
            Pairs([CallDetail.Header(name: "Made by", value: call.origin),
                   CallDetail.Header(name: "Type", value: call.type),
                   CallDetail.Header(name: "Served from", value: call.source.isEmpty ? "—" : call.source)]
                  + ((calls.detail?.initiator).map { $0.isEmpty ? [] : [CallDetail.Header(name: "Initiator", value: $0)] } ?? []),
                  sans: true)
        }
    }

    @ViewBuilder private var sent: some View {
        if let text = calls.detail?.requestBody {
            let length = calls.detail?.requestLength ?? text.count
            let type = calls.detail?.requestType ?? ""
            if text.isEmpty {
                Muted("Empty body.")
            } else if type.contains("x-www-form-urlencoded"), let items = URLComponents(string: "?" + text)?.queryItems, !items.isEmpty {
                Copyable(text: text) {
                    Pairs(items.prefix(100).map { CallDetail.Header(name: $0.name, value: $0.value ?? "") }, copies: false)
                }
            } else {
                BodyView(text: text, length: length, cut: calls.detail?.requestCut ?? false, mime: type, reader: calls.sentReader,
                         saveName: nil)
            }
        } else if calls.detail == nil {
            Unavailable(reason: calls.body == .reading ? "Reading…" : "This call belongs to an earlier inspection session.")
        } else if call.type == "beacon" || call.method != "GET" && call.method != "HEAD" {
            Muted("WebKit reported no body for this request.")
        } else {
            Muted("\(call.method) requests carry no body.")
        }
    }


    // MARK: Headers

    @ViewBuilder private var headers: some View {
        Color.clear.frame(height: 0).id(Self.top)
        if let detail = calls.detail {
            Block(title: "Response headers") {
                if detail.responseHeaders.isEmpty { Muted("None reported by WebKit.") } else { Pairs(detail.responseHeaders) }
            }
            Block(title: "Request headers") {
                if detail.requestHeaders.isEmpty { Muted("None reported by WebKit.") } else { Pairs(detail.requestHeaders) }
            }
        } else {
            Unavailable(reason: calls.body == .reading ? "Reading…" : "This call belongs to an earlier inspection session.")
        }
    }

    // MARK: Response

    @ViewBuilder private func response(_ proxy: ScrollViewProxy) -> some View {
        Color.clear.frame(height: 0).id(Self.top)
        switch calls.body {
        case .reading?, nil:
            HStack(spacing: metrics.length(Metrics.callsGap)) {
                MigrationSpinner()
                Muted(call.finished || call.failed ? "Reading the response from WebKit…" : "Waiting for the response to finish…")
            }
        case .unavailable(let reason)?:
            Unavailable(reason: reason)
        case .binary(let length)?:
            Unavailable(symbol: "doc", title: "Binary response",
                        reason: "\(call.mime.isEmpty ? "Unknown type" : call.mime), about \(Call.bytes(Double(length))). Not shown here.")
        case .text(let text, let length, let cut)?:
            if text.isEmpty {
                Muted("Empty response.")
            } else {
                BodyView(text: text, length: length, cut: cut, mime: call.mime, reader: calls.reader,
                         saveName: Self.fileName(call), mark: calls.mark, reveal: proxy, treeKeys: $treeKeys)
            }
        }
    }

    /// The last part of the path, named for what it holds.
    static func fileName(_ call: Call) -> String {
        let last = call.address?.lastPathComponent ?? ""
        let base = last.isEmpty || last == "/" ? "response" : last
        return base.hasSuffix(".json") || !call.mime.contains("json") ? base : base + ".json"
    }

    private var foot: some View {
        HStack(spacing: metrics.length(10)) {
            AgentCopy(copied: copied) {
                guard let report = browser.callReport(tabOf: calls) else { return }
                Clipboard.put(report)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            }
            Text("Markdown with tab context")
                .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                .foregroundStyle(Palette.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
            steps
        }
        .padding(.leading, metrics.length(Metrics.callsInset))
        .padding(.trailing, metrics.length(Metrics.callsInset - 4))
        .padding(.vertical, metrics.length(10))
    }

    /// The gesture, said by two arrows that also do it: up is the newer
    /// call, as the list stands newest first. Dimmed at either end.
    private var steps: some View {
        let newer = calls.neighbour(-1) != nil
        let older = calls.neighbour(1) != nil
        return HStack(spacing: 0) {
            Door(icon: "chevron.up", help: "Newer call   ↑", box: 22, glyph: 10) { calls.step(-1) }
                .disabled(!newer)
                .opacity(newer ? 1 : 0.35)
                .accessibilityLabel("Newer call")
            Door(icon: "chevron.down", help: "Older call   ↓", box: 22, glyph: 10) { calls.step(1) }
                .disabled(!older)
                .opacity(older ? 1 : 0.35)
                .accessibilityLabel("Older call")
        }
        .help("↑ ↓ go to the newer or older call of the list. In the JSON tree, ⌥↑ ⌥↓.")
    }
}

/// ↑ ↓ and ⌥↑ ⌥↓ for the opened call. SwiftUI's focus is lost to a click on
/// text or a blank part of the sheet, so the keys are watched on the window
/// while the sheet is on screen, and only then. Opening a call takes the
/// keyboard from the page; clicking the page gives it back, and the page and
/// a field being edited keep every arrow. The JSON tree, while it has the
/// keyboard, keeps the plain ones.
private struct StepKeys: NSViewRepresentable {
    let tree: Bool
    let step: (Int) -> Void

    func makeNSView(context: Context) -> Watch { Watch() }

    func updateNSView(_ view: Watch, context: Context) {
        view.tree = tree
        view.step = step
    }

    static func dismantleNSView(_ view: Watch, coordinator: ()) { view.stop() }

    final class Watch: NSView {
        var tree = false
        var step: ((Int) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                guard let window, Self.inPage(window.firstResponder) else { return }
                window.makeFirstResponder(nil)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let step = self.step, self.claims(event) else { return event }
                step(event.keyCode == 126 ? -1 : 1)
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func claims(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  event.keyCode == 125 || event.keyCode == 126 else { return false }
            if let text = window.firstResponder as? NSTextView, text.isEditable { return false }
            if Self.inPage(window.firstResponder) { return false }
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            return flags == .option || flags.isEmpty && !tree
        }

        static func inPage(_ responder: NSResponder?) -> Bool {
            var view = responder as? NSView
            while let each = view {
                if each is WKWebView { return true }
                view = each.superview
            }
            return false
        }
    }
}

/// Pauses and resumes recording. The symbol says what a click does: the
/// pause bars while recording, a red record dot while paused; the word
/// Paused beside the list's order says the state without the colour.
private struct RecordToggle: View {
    let recording: Bool
    let toggle: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            Image(systemName: recording ? "pause.fill" : "record.circle")
                .font(.system(size: metrics.length(recording ? 10 : 12), weight: .medium))
                .foregroundStyle(recording ? (hovering ? Palette.ink.opacity(0.7) : Palette.muted) : Palette.danger)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: metrics.length(26), height: metrics.length(26))
                .background(RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous)
                    .fill(hovering ? Palette.hover : .clear))
                .contentShape(RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: recording)
        .help(recording ? "Pause recording: the list is kept, new calls are not added"
                        : "Resume recording: new calls are added again")
        .accessibilityLabel(recording ? "Pause recording" : "Resume recording")
    }
}

/// A searched text shown where it was found: the occurrence on the marker's
/// yellow, the rest as it was.
enum Marked {
    /// A search result's excerpt, with an ellipsis where the response goes on.
    static func excerpt(_ match: CallSearch.Match, lead: Int = 14) -> Text {
        let before = match.before.count > lead ? String(match.before.suffix(lead)) : match.before
        return Text((match.head && before == match.before ? "" : "…") + before).foregroundColor(Palette.muted)
            + Text(highlight(match.hit)).foregroundColor(Palette.ink)
            + Text(match.after + (match.tail ? "" : "…")).foregroundColor(Palette.muted)
    }

    static func highlight(_ text: String) -> AttributedString {
        var marked = AttributedString(text)
        marked.backgroundColor = Palette.found
        return marked
    }

    /// `text` with every occurrence of `mark`, whatever its case, on the
    /// marker, at most `limit` of them.
    static func text(_ text: String, mark: String?, color: Color, limit: Int = 200) -> Text {
        guard let mark, !mark.isEmpty else { return Text(text).foregroundColor(color) }
        var result = AttributedString()
        var rest = text[...]
        var count = 0
        while count < limit, let range = rest.range(of: mark, options: [.caseInsensitive, .diacriticInsensitive]) {
            var before = AttributedString(rest[..<range.lowerBound])
            before.foregroundColor = color
            var hit = AttributedString(rest[range])
            hit.foregroundColor = color
            hit.backgroundColor = Palette.found
            result += before
            result += hit
            rest = rest[range.upperBound...]
            count += 1
        }
        var tail = AttributedString(rest)
        tail.foregroundColor = color
        result += tail
        return Text(result)
    }
}

/// The one ink action of a call: the call as a Markdown report an AI agent
/// can read (CallReport.swift). The sparkles say who it is for; the check
/// says it is on the pasteboard.
private struct AgentCopy: View {
    let copied: Bool
    let copy: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: metrics.length(6)) {
                Image(systemName: copied ? "checkmark" : "sparkles")
                    .font(.system(size: metrics.length(11), weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : "Copy for AI")
                    .font(.system(size: metrics.length(Metrics.callsText), weight: .medium))
            }
            .foregroundStyle(Palette.inverse)
            .padding(.horizontal, metrics.length(12))
            .padding(.vertical, metrics.length(6))
            .background(Palette.ink.opacity(hovering ? 0.85 : 1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .animation(Motion.quick, value: copied)
        .help("Copies this call for an AI agent: request, response, headers with credentials redacted, and the tab's context, as Markdown.")
        .accessibilityLabel(copied ? "Copied" : "Copy for AI agent")
    }
}

extension Browser {
    /// The report for the tab whose panel shows `calls`.
    fileprivate func callReport(tabOf calls: Calls) -> String? {
        guard let tab = (tabs + parkedTabs).first(where: { $0.id == calls.tab }) else { return nil }
        return callReport(tab)
    }
}

/// A body as exchanged: structured when the JSON reader can hold it, raw
/// otherwise, with copy (and save, for a response) where the pointer is.
private struct BodyView: View {
    let text: String
    let length: Int
    let cut: Bool
    let mime: String
    @ObservedObject var reader: JSONReader
    /// A file name offered by Save; nil offers no saving.
    let saveName: String?
    /// The text the list's search found in it, marked where it stands.
    var mark: String? = nil
    /// Scrolls the raw text to the first occurrence of `mark`.
    var reveal: ScrollViewProxy? = nil
    /// Whether the JSON tree has the keyboard, for the sheet's arrows.
    var treeKeys: Binding<Bool>? = nil
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var raw = false
    @FocusState private var searching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(8)) {
            HStack(spacing: metrics.length(Metrics.callsGap)) {
                if reader.shown {
                    Segmented(options: [(false, "Structured"), (true, "Raw")], selection: $raw)
                }
                Spacer(minLength: 0)
                Text([mime, "\(length) characters"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: metrics.length(Metrics.callsSmall)))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            if cut {
                Muted("WebKit's body is longer: the first \(text.count) characters were read. The structured view needs the whole document.")
            }
            if reader.shown && !raw && ((reader.document?.nodes.count ?? 0) > 30 || !reader.query.isEmpty) {
                Hunt(text: $reader.query, prompt: "Search keys and values", focus: $searching)
            }
            Copyable(text: text, saveName: saveName, card: true) {
                if reader.shown && !raw {
                    JSONTree(reader: reader, holds: treeKeys)
                } else {
                    Mono(text, limit: 40_000, card: false, mark: mark, reveal: reveal)
                }
            }
        }
    }
}

// MARK: - The JSON tree

/// The JSON reader's index (JSONReader.swift) drawn as a console draws a
/// value: one line per member, a preview of what a container holds, keys,
/// text and numbers lightly tinted. Click or Return opens and closes; the
/// arrows move and open as in a Finder list; ⌘C copies the chosen value.
private struct JSONTree: View {
    @ObservedObject var reader: JSONReader
    /// Says whether the tree has the keyboard, and so the plain arrows.
    var holds: Binding<Bool>? = nil
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var chosen: Int?
    @FocusState private var focused: Bool
    static let shown = 1000

    var body: some View {
        if let error = reader.error {
            Unavailable(symbol: "curlybraces", title: "Not readable as JSON", reason: error)
        } else if let document = reader.document {
            let rows = Array(reader.visible.prefix(Self.shown))
            VStack(alignment: .leading, spacing: 0) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows, id: \.self) { id in
                        TreeLine(document: document, id: id, open: reader.expanded.contains(id),
                                 chosen: chosen == id && focused, searching: !reader.query.isEmpty, mark: reader.query) {
                            chosen = id
                            focused = true
                            if !document.nodes[id].children.isEmpty && reader.query.isEmpty { reader.toggle(id) }
                        }
                    }
                }
                if reader.visible.count > Self.shown {
                    Muted("\(reader.visible.count) lines; the first \(Self.shown) are shown. Search narrows them.")
                        .padding(.top, metrics.length(6))
                }
            }
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in move(press.key, in: document, rows: rows) }
            .onChange(of: focused) { holds?.wrappedValue = focused }
            .onDisappear { holds?.wrappedValue = false }
            .onCopyCommand {
                guard let chosen else { return [] }
                return [NSItemProvider(object: document.value(chosen) as NSString)]
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("JSON")
        } else {
            HStack(spacing: metrics.length(Metrics.callsGap)) { MigrationSpinner(); Muted("Reading JSON…") }
        }
    }

    private func move(_ key: KeyEquivalent, in document: JSONDocument, rows: [Int]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = chosen.flatMap { rows.firstIndex(of: $0) }
        let node = chosen.map { document.nodes[$0] }
        switch key {
        case .downArrow:
            chosen = rows[min((current ?? -1) + 1, rows.count - 1)]
        case .upArrow:
            chosen = rows[max((current ?? 1) - 1, 0)]
        case .rightArrow:
            guard let chosen, let node, !node.children.isEmpty else { return .handled }
            if !reader.expanded.contains(chosen) { reader.toggle(chosen) }
            else if let first = node.children.first { self.chosen = first }
        case .leftArrow:
            guard let chosen, let node else { return .handled }
            if reader.expanded.contains(chosen) && !node.children.isEmpty { reader.toggle(chosen) }
            else if let parent = node.parent, rows.contains(parent) { self.chosen = parent }
        case .return, .space:
            if let chosen, let node, !node.children.isEmpty { reader.toggle(chosen) }
        default:
            return .ignored
        }
        return .handled
    }
}

private struct TreeLine: View {
    let document: JSONDocument
    let id: Int
    let open: Bool
    let chosen: Bool
    let searching: Bool
    /// What the tree's search looks for, marked where it stands.
    let mark: String
    let tap: () -> Void
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let node = document.nodes[id]
        let leaf = node.children.isEmpty
        let shape = RoundedRectangle(cornerRadius: metrics.length(5), style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: metrics.length(4)) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: metrics.length(6.5)))
                .foregroundStyle(Palette.muted)
                .rotationEffect(.degrees(open && !searching ? 90 : 0))
                .animation(reduceMotion ? nil : Motion.quick, value: open)
                .opacity(leaf ? 0 : 1)
                .frame(width: metrics.length(9))
            line(node, leaf: leaf)
                .lineLimit(searching ? 2 : 1)
                .truncationMode(.tail)
            Spacer(minLength: metrics.length(2))
        }
        .font(.system(size: metrics.length(Metrics.callsMono), design: .monospaced))
        .padding(.leading, CGFloat(min(searching ? 0 : node.depth, 12)) * metrics.length(Metrics.callsIndent) + metrics.length(2))
        .padding(.vertical, metrics.length(2.5))
        .background(shape.fill(chosen ? Palette.selection : hovering ? Palette.hover : .clear))
        .overlay(alignment: .trailing) {
            if hovering || chosen {
                CopyButton(help: "Copy value") { Clipboard.put(document.value(id)) }
                    .background(Palette.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: metrics.length(5), style: .continuous))
                    .padding(.trailing, metrics.length(2))
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .onTapGesture(perform: tap)
        .contextMenu {
            Button("Copy Value") { Clipboard.put(document.value(id)) }
            Button("Copy Path") { Clipboard.put(document.path(id)) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(leaf ? [] : .isButton)
        .accessibilityValue(leaf ? "" : (open ? "expanded" : "collapsed"))
    }

    /// `key: value`, or the value alone at the top; a container shows its
    /// preview, as a console does, dimmed while it is open.
    private func line(_ node: JSONDocument.Node, leaf: Bool) -> Text {
        var text = Text("")
        if let parent = node.parent {
            let inArray = document.nodes[parent].kind == "array"
            let key = node.label.count > 200 ? String(node.label.prefix(199)) + "…" : node.label
            text = text + Marked.text(key, mark: searching ? mark : nil, color: inArray ? Palette.muted : Palette.codeKey)
                + Text(": ").foregroundColor(Palette.muted)
        }
        let pieces = leaf ? [document.leaf(id)] : document.preview(id)
        for piece in pieces {
            text = text + Marked.text(piece.text, mark: searching && leaf ? mark : nil, color: Self.color(piece.tone, dim: !leaf && open))
        }
        return text
    }

    static func color(_ tone: JSONDocument.Tone, dim: Bool) -> Color {
        let color: Color
        switch tone {
        case .plain, .null: color = Palette.muted
        case .key: color = Palette.codeKey
        case .string: color = Palette.codeString
        case .number, .literal: color = Palette.codeNumber
        }
        return dim ? color.opacity(0.7) : color
    }
}

// MARK: - Pieces

enum Clipboard {
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// A titled part of a call's detail.
private struct Block<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            Text(title)
                .font(.system(size: metrics.length(Metrics.callsSmall), weight: .medium))
                .foregroundStyle(Palette.muted)
                .textCase(.uppercase)
                .kerning(0.3)
            content()
        }
    }
}

/// Copy, and optionally save, at the top right of a block while the pointer
/// is over it. The button says when it has copied.
private struct Copyable<Content: View>: View {
    let text: String
    var saveName: String? = nil
    /// Draw the block's own card (a tree or text inside it needs one).
    var card = false
    @ViewBuilder let content: () -> Content
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
        content()
            .padding(card ? metrics.length(8) : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if card { shape.fill(Palette.raised) } }
            .overlay { if card { shape.strokeBorder(Palette.hairline, lineWidth: 1) } }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    HStack(spacing: metrics.length(2)) {
                        if let saveName { SaveIcon(text: text, name: saveName) }
                        CopyButton(help: "Copy") { Clipboard.put(text) }
                    }
                    .padding(metrics.length(3))
                    .background(Palette.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: metrics.length(7), style: .continuous))
                    .padding(metrics.length(4))
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: metrics.length(4))))
                }
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : Motion.quick, value: hovering)
    }
}

/// Saves the text to a file the person chooses (the system's save panel).
private struct SaveIcon: View {
    let text: String
    let name: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var hovering = false

    var body: some View {
        Button(action: save) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: metrics.length(10), weight: .medium))
                .foregroundStyle(hovering ? Palette.ink : Palette.muted)
                .frame(width: metrics.length(20), height: metrics.length(20))
                .background(RoundedRectangle(cornerRadius: metrics.length(5), style: .continuous)
                    .fill(hovering ? Palette.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Save…")
        .accessibilityLabel("Save response")
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = name.hasSuffix(".json") ? [.json] : [.plainText, .data]
        panel.allowsOtherFileTypes = true
        let text = self.text
        let write: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(text.utf8).write(to: url, options: .atomic) } catch { NSSound.beep() }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }
}

/// Names and values, one under the other when the panel is narrow; each
/// value can be copied from its own line.
private struct Pairs: View {
    let pairs: [CallDetail.Header]
    var sans = false
    var copies = true
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    init(_ pairs: [CallDetail.Header], sans: Bool = false, copies: Bool = true) {
        self.pairs = pairs
        self.sans = sans
        self.copies = copies
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { index, pair in
                if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
                PairLine(pair: pair, sans: sans, copies: copies)
            }
        }
        .background(Palette.raised, in: RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
    }
}

private struct PairLine: View {
    let pair: CallDetail.Header
    let sans: Bool
    let copies: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: metrics.length(6)) {
            VStack(alignment: .leading, spacing: metrics.length(2)) {
                Text(pair.name)
                    .font(.system(size: metrics.length(Metrics.callsSmall), design: sans ? .default : .monospaced))
                    .foregroundStyle(sans ? Palette.muted : Palette.codeKey)
                Text(pair.value.isEmpty ? "—" : pair.value)
                    .font(.system(size: metrics.length(Metrics.callsMono), design: sans ? .default : .monospaced))
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if copies && hovering && !pair.value.isEmpty {
                CopyButton(help: "Copy " + pair.name) { Clipboard.put(pair.value) }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: metrics.length(4))))
            }
        }
        .padding(.horizontal, metrics.length(10))
        .padding(.vertical, metrics.length(6))
        .frame(maxWidth: .infinity, alignment: .leading)
        // A plain rectangle: the card's own rounding clips the first and
        // last lines, and a line between two others stays square.
        .background { Rectangle().fill(hovering && copies ? Palette.hover : .clear) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.quick, value: hovering)
    }
}

/// Text as it was exchanged, selectable, bounded for drawing. A searched
/// text is marked, and the view scrolls to its first occurrence: the text is
/// drawn in two parts, the second starting on that occurrence's line.
private struct Mono: View {
    let text: String
    var limit = 4096
    var card = true
    var mark: String?
    var reveal: ScrollViewProxy?
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    init(_ text: String, limit: Int = 4096, card: Bool = true, mark: String? = nil, reveal: ScrollViewProxy? = nil) {
        self.text = text
        self.limit = limit
        self.card = card
        self.mark = mark
        self.reveal = reveal
    }

    static let found = "found"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous)
        let drawn = text.count > limit ? String(text.prefix(limit)) : text
        let first = mark.flatMap { drawn.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) }
        VStack(alignment: .leading, spacing: metrics.length(6)) {
            VStack(alignment: .leading, spacing: 0) {
                if let first {
                    // From the start of the line the first occurrence is on.
                    let start = drawn[..<first.lowerBound].lastIndex(of: "\n").map { drawn.index(after: $0) } ?? first.lowerBound
                    if start > drawn.startIndex {
                        piece(String(drawn[..<drawn.index(before: start)]))
                    }
                    piece(String(drawn[start...]))
                        .id(Self.found)
                        .onAppear {
                            guard let reveal else { return }
                            DispatchQueue.main.async { reveal.scrollTo(Self.found, anchor: .top) }
                        }
                } else {
                    piece(drawn)
                }
            }
            .padding(card ? metrics.length(10) : metrics.length(2))
            .background { if card { shape.fill(Palette.raised) } }
            .overlay { if card { shape.strokeBorder(Palette.hairline, lineWidth: 1) } }
            if text.count > limit {
                Muted("The first \(limit) of \(text.count) characters are drawn; Copy copies all that was read.")
            }
            if let mark, first == nil, text.range(of: mark, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                Muted("“\(mark)” is past the part drawn here.")
            }
        }
    }

    private func piece(_ part: String) -> some View {
        Marked.text(part, mark: mark, color: Palette.ink)
            .font(.system(size: metrics.length(Metrics.callsMono), design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Muted: View {
    let text: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
            .foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What WebKit could not give, and why, in place of the missing content.
private struct Unavailable: View {
    var symbol = "eye.slash"
    var title = "Unavailable"
    let reason: String
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        HStack(alignment: .top, spacing: metrics.length(10)) {
            Image(systemName: symbol)
                .font(.system(size: metrics.length(13)))
                .foregroundStyle(Palette.muted)
                .frame(width: metrics.length(18))
            VStack(alignment: .leading, spacing: metrics.length(3)) {
                Text(title)
                    .font(.system(size: metrics.length(Metrics.callsText), weight: .medium))
                    .foregroundStyle(Palette.ink)
                Text(reason)
                    .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(metrics.length(12))
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A state of the collection itself, with what can be done about it.
private struct Notice<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder let actions: () -> Actions
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.length(8)) {
            HStack(alignment: .top, spacing: metrics.length(8)) {
                Image(systemName: symbol)
                    .font(.system(size: metrics.length(13)))
                    .foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: metrics.length(2)) {
                    Text(title)
                        .font(.system(size: metrics.length(Metrics.callsText), weight: .medium))
                        .foregroundStyle(Palette.ink)
                    Text(text)
                        .font(.system(size: metrics.length(Metrics.callsSmall + 0.5)))
                        .foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            actions()
        }
        .padding(metrics.length(10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.cardRadius, style: .continuous))
    }
}
