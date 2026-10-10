// Bearings: the compact search surface shared by New Tab, ⌘L and ⌘K. The
// name is what people see (field, Settings › Keyboard, README); the type keeps
// its old name until a rename of its own. The field and
// results share one glass layer; bounded rows stay inside the available page
// at every interface size. Environment values belong to the selected result,
// expanding inside that same row. Only the chosen environment takes the focus
// ring, so keyboard focus never appears detached below unrelated results.
// The list carries no footer of key hints: the selected row says what Return
// does, and its environment row says what the arrows do, where each applies.
// ⌘T and ⌘K each pair with GitHub in a capsule at the end of the field
// (Modes.swift, Bearing.swift), so GitHub reads as a mode of the same bar, not
// a place; Tab switches the pair. ⌘L, which changes this page's address, shows no modes.
import SwiftUI
import AppKit

struct Omnibox: View {
    let browser: Browser
    @ObservedObject var input: Field
    let over: Bool
    let corner: CGFloat
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var refused = false
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reducedMotion

    var body: some View {
        GeometryReader { bounds in
            ZStack {
                if over {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Palette.ground.opacity(0.74))
                        .onTapGesture { browser.dismiss() }
                }
                VStack(spacing: 0) {
                    if Store.testing && Store.settings.bool(forKey: "githubPrototype") {
                        GitHubPrototype(maxResultsHeight: min(bounds.size.height * 0.5,
                            max(0, bounds.size.height - metrics.length(Metrics.searchLift * 2 + Metrics.githubPreviewChromeHeight))))
                    } else {
                        HStack(spacing: metrics.length(Metrics.searchInset)) {
                            Image(systemName: input.opening?.shy == true ? "eye.slash" : "magnifyingglass")
                                .foregroundStyle(Palette.muted)
                                .font(.system(size: metrics.length(Metrics.searchFont)))
                            AddressField(browser: browser, input: input, fontSize: metrics.length(Metrics.searchFont))
                                .accessibilityLabel(input.github != nil ? "Bearings: search GitHub" : "Bearings: search or enter an address")
                                .accessibilityValue(input.ringedEnvironment.map { "Environment: \($0.name)" } ?? input.completed)
                            if let pair = bearings {
                                Modes(modes: pair, selection: browser.bearing ?? .newTab) { browser.choose($0) }
                                    .accessibilityLabel("Bearings mode")
                            }
                        }
                        .padding(.horizontal, metrics.length(Metrics.searchInset))
                        .frame(height: metrics.length(Metrics.searchFieldHeight))
                        if let search = input.github {
                            Divider().overlay(Palette.hairline)
                            GitHubResults(browser: browser, search: search, maxHeight: bounds.size.height * 0.5)
                        } else if !input.offers.isEmpty {
                            Divider().overlay(Palette.hairline)
                            ScrollViewReader { scroll in
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(Array(input.offers.enumerated()), id: \.element.id) { index, offer in
                                            Row(offer: offer, icon: browser.tabs.first { $0.id == offer.tab }?.icon,
                                                input: input, picked: input.picked == index) { browser.take(offer) }
                                                .id(index)
                                        }
                                    }
                                    .padding(metrics.length(Metrics.searchGap))
                                }
                                .frame(height: min(CGFloat(input.offers.count) * metrics.length(Metrics.searchRowHeight)
                                                   + metrics.length(Metrics.searchGap * 2)
                                                   + (input.showsEnvironments ? metrics.length(Metrics.searchEnvironmentHeight) : 0), bounds.size.height * 0.5))
                                .onChange(of: input.picked) { _, index in
                                    if let index { scroll.scrollTo(index) }
                                }
                            }
                        }
                    }
                }
                .shortcutAnimation(Motion.githubMode, value: input.github != nil,
                                   enabled: browser.prefs.fasterShortcuts, reduced: reducedMotion)
                .frame(width: min(metrics.fieldWidth, max(0, bounds.size.width - metrics.length(Metrics.searchInset * 2))))
                .glass(.panel, in: RoundedRectangle(cornerRadius: metrics.fieldRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.fieldRadius)
                        .strokeBorder(refused ? Palette.danger : Palette.hairline, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .background(SearchDismissal { browser.dismiss() })
                // The field's top stays put and the list grows below it, so a
                // mode with fewer results never moves the field under the eye.
                .padding(.top, bounds.size.height * Metrics.searchTop)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { input.refresh() }
        .onReceive(browser.$tabs.dropFirst()) { _ in
            // @Published emits before assignment; refresh after the mutation.
            DispatchQueue.main.async { input.refresh() }
        }
        .onReceive(browser.bookmarks.$roots.dropFirst()) { _ in
            DispatchQueue.main.async { input.refresh() }
        }
        .onReceive(browser.$shelfTabs.dropFirst()) { _ in
            DispatchQueue.main.async { input.refresh() }
        }
        .onChange(of: input.refusals) { _, _ in refused = true }
        .onChange(of: input.typed) { _, _ in refused = false }
    }

    // MARK: - modes

    /// The pair on screen (Bearing.swift), or none while editing this page's address.
    private var bearings: [Modes<Bearing>.Mode]? {
        guard let partner = browser.bearingPartner else { return nil }
        return .pair(partner, shy: browser.searchIsPrivate, hint: hint)
    }

    /// The tooltip names the mode, its shortcut as bound, and Tab, which switches the pair.
    private func hint(_ title: String, _ action: KeyAction) -> String {
        guard let stroke = browser.prefs.keyBindings.keys(action).first else { return "\(title)   ⇥" }
        return "\(title)   \(stroke.label) · ⇥"
    }

    private struct Row: View {
        let offer: Suggestion
        let icon: NSImage?
        @ObservedObject var input: Field
        let picked: Bool
        let take: () -> Void
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        @State private var hovering = false

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                heading
                    .contentShape(Rectangle())
                    .onTapGesture(perform: take)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { take() }
                if picked, input.showsEnvironments {
                    SearchEnvironmentChoices(input: input)
                        .frame(height: metrics.length(Metrics.searchEnvironmentHeight))
                }
            }
            .background {
                if picked {
                    Chosen(radius: metrics.length(Metrics.searchRowRadius))
                } else if hovering {
                    RoundedRectangle(cornerRadius: metrics.length(Metrics.searchRowRadius)).fill(Palette.hover)
                }
            }
            .accessibilityAddTraits(picked ? .isSelected : [])
            .onHover { hovering = $0 }
        }

        private var heading: some View {
            HStack(spacing: metrics.length(Metrics.searchInset)) {
                if offer.kind == .search || offer.kind == .keyword || offer.kind == .command {
                    Image(systemName: offer.kind == .command ? "command" : "magnifyingglass")
                        .foregroundStyle(Palette.muted)
                        .frame(width: metrics.length(Metrics.searchIcon))
                } else {
                    Mark(icon: icon,
                         letter: String((offer.url.host() ?? "•").prefix(1)).uppercased(),
                         size: metrics.length(Metrics.searchIcon))
                }
                // A keyword's row says what Return does: "Search npmjs.com for react".
                Text(offer.kind == .keyword ? offer.title : offer.key)
                    .font(.system(size: metrics.length(Metrics.searchFont)))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let environment = offer.activeEnvironment {
                    Text(environment.badge)
                        .font(.system(size: metrics.length(Metrics.searchDetail), weight: .medium))
                        .foregroundStyle(environment.colour.map(Palette.swatchInk) ?? Palette.ink)
                        .padding(.horizontal, metrics.length(Metrics.searchGap))
                        .padding(.vertical, metrics.length(Metrics.searchBadgeInset))
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.searchGap)))
                        .fixedSize()
                        .help("Active environment: \(environment.name)")
                        .accessibilityLabel("Active environment: \(environment.name)")
                }
                if offer.kind != .keyword {
                    Text(offer.title)
                        .font(.system(size: metrics.length(Metrics.searchDetail)))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if picked {
                    HStack(spacing: metrics.length(Metrics.searchGap)) {
                        Image(systemName: "return").accessibilityHidden(true)
                        Text(offer.kind == .command ? "Run"
                             : offer.kind == .open && input.selectedEnvironment == nil ? "Switch to tab" : "Open")
                    }
                    .font(.system(size: metrics.length(Metrics.searchDetail)))
                    .foregroundStyle(Palette.muted)
                    .fixedSize()
                }
            }
            .padding(.horizontal, metrics.length(Metrics.searchInset))
            .frame(height: metrics.length(Metrics.searchRowHeight))
        }
    }
}

/// A title-bar drag view receives clicks before SwiftUI's transparent layers.
/// Watch only while the search card is mounted, using its real window bounds,
/// so clicks in the chrome/margins close it without tinting or blocking them.
private struct SearchDismissal: NSViewRepresentable {
    let dismiss: () -> Void
    func makeNSView(context: Context) -> Boundary { Boundary() }
    func updateNSView(_ view: Boundary, context: Context) { view.dismiss = dismiss }
    static func dismantleNSView(_ view: Boundary, coordinator: ()) { view.unwatch() }

    final class Boundary: NSView {
        var dismiss: () -> Void = {}
        private var watcher: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            unwatch()
            guard window != nil else { return }
            watcher = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, event.window === self.window,
                      !self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                self.dismiss()
                return event
            }
        }
        func unwatch() {
            if let watcher { NSEvent.removeMonitor(watcher) }
            watcher = nil
        }
    }
}

/// The field itself, in AppKit.
///
/// SwiftUI's TextField can hold a string and nothing else, and the whole point
/// here is the part you didn't type: the rest of the address, already there and
/// selected, so carrying on typing replaces it and Return accepts it. That
/// needs a real text field and its delegate.
struct AddressField: NSViewRepresentable {
    /// For Return; what the field holds is `input`'s.
    let browser: Browser
    @ObservedObject var input: Field
    var fontSize: CGFloat = 15.5

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, input: input) }

    func makeNSView(context: Context) -> NSTextField {
        let field = Box()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = Palette.NS.ink
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        // SwiftUI picks its own colour for a placeholder, and on a pale ground
        // that colour was near-white.
        field.placeholderAttributedString = NSAttributedString(
            string: input.github != nil ? "Bearings · Search pull requests and issues" : input.opening?.shy == true ? "Bearings · Search privately or enter an address" : "Bearings · Search or enter an address",
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor(Palette.ink.opacity(0.3)),
            ]
        )
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.browser = browser
        coordinator.input = input
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderAttributedString = NSAttributedString(
            string: input.github != nil ? "Bearings · Search pull requests and issues" : input.opening?.shy == true ? "Bearings · Search privately or enter an address" : "Bearings · Search or enter an address",
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor(Palette.ink.opacity(0.3)),
            ]
        )

        // Only when something other than typing changed it — ⌘L arriving with
        // an address, a walk through the list, a submit clearing it.
        //
        // Comparing against the field's own text instead would undo every
        // backspace: deleting leaves the field shorter than what the browser
        // still considers complete, and the next update would helpfully type
        // it back in. That is a field you cannot shorten, and it reads exactly
        // like one that has stopped responding.
        let want = input.completed
        if want != coordinator.synced {
            coordinator.synced = want
            field.stringValue = want
            // Only an ending of what was typed is selected; a walked-to
            // address that doesn't extend it keeps the caret at its end.
            coordinator.select(from: want.hasPrefix(input.typed) ? input.typed.utf16.count : want.utf16.count, in: field)
        }

        if coordinator.answered != input.focusRequest {
            coordinator.answered = input.focusRequest
            let selectAll = input.focusSelectsAll
            let request = input.focusRequest
            (field as? Box)?.given = { [weak input] in input?.focusGiven = request }
            DispatchQueue.main.async { Self.focus(field, selectAll: selectAll) }
        }
    }

    /// The keyboard into the field, with everything in it selected.
    ///
    /// A field asked for focus between SwiftUI making it and putting it in
    /// the window has no window to take the keyboard in, and the request was
    /// spent on nothing: the field came up over the page with the keyboard
    /// still in the page. It happened 3 times in 440 openings by ⌘L after
    /// Escape, and 23 in 320 once the field had an owner of its own, asked
    /// again sooner, without the whole window being redrawn first (bench;
    /// see Field.swift). Such a field now takes the keyboard
    /// when it arrives (see Box): none in 160.
    static func focus(_ field: NSTextField, selectAll: Bool = true) {
        guard let window = field.window else {
            (field as? Box)?.owed = true
            return
        }
        (field as? Box)?.owed = false
        guard window.makeFirstResponder(field) else { return }
        (field as? Box)?.markFocused()
        guard let editor = field.currentEditor() as? NSTextView else { return }
        // The system paints selected text as a block of accent colour,
        // which over this pale field is the loudest thing in the
        // window. A tenth of the ink says "selected" quietly enough.
        editor.selectedTextAttributes = [
            .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
            .foregroundColor: Palette.NS.ink,
        ]
        if selectAll { editor.selectAll(nil) }
        else { editor.setSelectedRange(NSRange(location: field.stringValue.utf16.count, length: 0)) }
        (field as? Box)?.given?()
    }

    /// The field, holding on to a focus asked for before it had a window.
    final class Box: NSTextField {
        var owed = false
        /// Says which focus request the keyboard arriving here answers.
        var given: (() -> Void)?
        /// First successful focus, for launch measurements only. The absolute
        /// uptime lets the external collector use the same monotonic clock
        /// without adding a timer or polling the application while it starts.
        private(set) var firstFocusedAt: TimeInterval?

        func markFocused() {
            guard Store.measuring, firstFocusedAt == nil else { return }
            firstFocusedAt = ProcessInfo.processInfo.systemUptime
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard owed, window != nil else { return }
            AddressField.focus(self)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var browser: Browser
        var input: Field
        var answered = -1
        /// The last value pushed in from the browser side, so an update can
        /// tell a change worth applying from one it made itself.
        var synced = ""

        /// A backspace has to be allowed to actually take a letter off. Without
        /// this the field puts the same letter straight back as a completion
        /// and the address can never be shortened.
        private var deleting = false

        init(browser: Browser, input: Field) {
            self.browser = browser
            self.input = input
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let text = field.stringValue

            input.typed = text
            guard !deleting, let ending = input.ending else {
                if deleting { input.stopCompleting() }
                deleting = false
                synced = input.completed
                return
            }
            deleting = false

            field.stringValue = text + ending
            synced = field.stringValue
            select(from: text.utf16.count, in: field)
        }

        /// The part after the caret, shown as selected, so the next keystroke
        /// replaces it and Return takes it. `start` is in UTF-16 units, as
        /// `NSRange` is.
        func select(from start: Int, in field: NSTextField) {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.selectedTextAttributes = [
                .backgroundColor: NSColor(Palette.ink.opacity(0.12)),
                .foregroundColor: Palette.NS.ink,
            ]
            let length = field.stringValue.utf16.count
            guard start <= length else { return }
            editor.selectedRange = NSRange(location: start, length: length - start)
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy command: Selector
        ) -> Bool {
            switch command {
            case #selector(NSResponder.insertNewline(_:)):
                browser.submit()
                return true
            case #selector(NSResponder.moveLeft(_:)):
                guard input.environmentFocused else { return false }
                input.moveEnvironment(-1)
                return true
            case #selector(NSResponder.moveRight(_:)):
                if input.environmentFocused { input.moveEnvironment(1); return true }
                // At the end of the line, with no completion left to take, the
                // right arrow steps into the chosen bookmark's environments.
                let range = textView.selectedRange()
                guard range.length == 0, range.location == (textView.string as NSString).length else { return false }
                return input.focusEnvironments()
            case #selector(NSResponder.moveDown(_:)):
                input.walk(1)
                return true
            case #selector(NSResponder.moveUp(_:)):
                input.walk(-1)
                return true
            case #selector(NSResponder.deleteBackward(_:)),
                 #selector(NSResponder.deleteForward(_:)):
                deleting = true
                return false
            default:
                return false
            }
        }
    }
}

extension Array where Element == Modes<Bearing>.Mode {
    /// A Bearings pair: the search it was opened as, then GitHub. Shared with the
    /// specimen in the arrival and Settings › GitHub, so both draw the real capsule.
    static func pair(_ partner: Bearing, shy: Bool, hint: (String, KeyAction) -> String) -> [Modes<Bearing>.Mode] {
        let first: Modes<Bearing>.Mode
        if partner == .tabs {
            first = .init(option: .tabs, glyph: .symbol("square.on.square"), title: "Tabs", help: hint("Tabs", .searchTabs))
        } else {
            let title = shy ? "Private Tab" : "New Tab"
            first = .init(option: .newTab, glyph: .symbol(shy ? "eye.slash" : "plus"), title: title,
                          help: hint(title, shy ? .privateTab : .newTab))
        }
        return [first, .init(option: .github, glyph: GitHubMark.glyph.map { .image($0) } ?? .symbol("arrow.triangle.pull"),
                             title: "GitHub", help: hint("GitHub", .searchGitHub))]
    }
}
