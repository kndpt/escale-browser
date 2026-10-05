// Keyboard is a searchable command list, not a stack of settings cards. The
// toolbar stays in view while groups scroll; one inline recorder keeps a change
// beside its command and explains collisions before a single snapshot is saved.
import SwiftUI
import AppKit

struct KeyboardSettings: View {
    @ObservedObject var prefs: Preferences
    @StateObject private var capture = KeyCapture()
    @State private var query = ""
    @State private var group: KeyGroup?
    @State private var filter = KeyFilter.all
    @State private var confirmingReset = false
    @State private var notice = ""
    @FocusState private var searchFocused: Bool
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @SwiftUI.Environment(\.accessibilityReduceMotion) private var reduced

    enum KeyFilter: String, CaseIterable { case all = "All", modified = "Modified", unassigned = "Unassigned" }

    private var commands: [KeyCommand] {
        KeyCommand.all.filter {
            (group == nil || group == $0.group) && prefs.keyBindings.matches($0, query: query)
                && (filter != .modified || prefs.keyBindings.changed($0.action))
                && (filter != .unassigned || prefs.keyBindings.keys($0.action).isEmpty)
        }
    }
    private var references: [KeyReference] {
        guard filter == .all, group == nil || group == .reference else { return [] }
        return KeyReference.all.filter { item in
            let words = KeyBindings.words(query)
            let keyWords = KeyBindings.words(item.keys)
            let haystack = item.title + " " + item.owner + " " + item.detail
            return words.allSatisfy { word in
                let isKey = word.count == 1 || ["cmd", "command", "ctrl", "control", "alt", "option", "shift"].contains(word)
                let canonical = ["cmd": "command", "ctrl": "control", "alt": "option"][word] ?? word
                return isKey ? keyWords.contains(canonical) : haystack.localizedStandardContains(word) || keyWords.contains(word)
            }
        }
    }
    private var modifiedCount: Int { KeyAction.allCases.filter { prefs.keyBindings.changed($0) }.count }

    var body: some View {
        GeometryReader { area in
            content(pinned: area.size.height >= metrics.length(Metrics.keyboardPinnedHeight))
        }
    }

    private func content(pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
            if pinned { toolbar(compact: false) }
            if pinned && confirmingReset { resetConfirmation }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardSectionGap), pinnedViews: []) {
                        if !pinned { toolbar(compact: true) }
                        if !pinned && confirmingReset { resetConfirmation }
                        let found = commands
                        ForEach(KeyGroup.allCases.filter { $0 != .reference }) { section in
                            let items = found.filter { $0.group == section }
                            if !items.isEmpty {
                                VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
                                    heading(section.rawValue, count: items.count)
                                    VStack(spacing: 0) {
                                        ForEach(items) { command in
                                            commandRow(command)
                                            if command.id != items.last?.id { rule }
                                        }
                                    }
                                }
                            }
                        }
                        if !references.isEmpty {
                            VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardSectionGap)) {
                                VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
                                    heading(KeyGroup.reference.rawValue, count: references.count)
                                    Text("These shortcuts belong to the focused editor or macOS. You can look them up here; they cannot be changed in Escale.")
                                        .font(.system(size: metrics.length(Metrics.keyboardDetail)))
                                        .foregroundStyle(Palette.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                ForEach(["Editing", "Context", "macOS"], id: \.self) { owner in
                                    let items = references.filter { $0.owner == owner }
                                    if !items.isEmpty {
                                        VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
                                            Label(owner, systemImage: "lock")
                                                .font(.system(size: metrics.length(Metrics.keyboardDetail), weight: .medium))
                                                .foregroundStyle(Palette.muted)
                                            VStack(spacing: 0) {
                                                ForEach(items) { reference in
                                                    referenceRow(reference)
                                                    if reference.id != items.last?.id { rule }
                                                }
                                            }
                                        }
                                    }
                                }
                                Button("Open macOS Keyboard Settings…") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                                }
                                .buttonStyle(KeyControlStyle())
                            }
                        }
                        if found.isEmpty && references.isEmpty {
                            VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
                                Text(query.isEmpty ? (filter == .modified ? "Your shortcuts are at their defaults." : "No commands in this view.") : "No shortcuts found")
                                    .font(.system(size: metrics.length(Metrics.settingsRowText), weight: .medium))
                                Text("Try a command name, a category or keys such as “cmd shift t”.")
                                    .font(.system(size: metrics.length(Metrics.keyboardDetail)))
                                    .foregroundStyle(Palette.muted)
                                Button("Show all shortcuts") { query = ""; group = nil; filter = .all }
                                    .buttonStyle(KeyControlStyle())
                            }.padding(.vertical, metrics.length(Metrics.keyboardSectionGap))
                        }
                    }
                    .id("top")
                    .padding(.bottom, metrics.length(Metrics.keyboardSectionGap))
                }
                .onChange(of: query) { _, _ in capture.cancel(); proxy.scrollTo("top", anchor: .top) }
                .onChange(of: group) { _, _ in capture.cancel(); proxy.scrollTo("top", anchor: .top) }
                .onChange(of: filter) { _, _ in capture.cancel(); proxy.scrollTo("top", anchor: .top) }
                .onChange(of: capture.action) { _, action in
                    if let action { withAnimation(reduced ? nil : Motion.quick) { proxy.scrollTo(action.rawValue, anchor: .center) } }
                }
            }
            if !notice.isEmpty {
                Text(notice).font(.system(size: metrics.length(Metrics.keyboardDetail))).foregroundStyle(Palette.muted)
                    .accessibilityLabel(notice)
            }
        }
        .onChange(of: searchFocused) { _, focused in if focused { capture.cancel() } }
        .onChange(of: capture.commitRequest) { _, _ in
            // Return saves an unambiguous assignment only. Replacing another
            // command always needs the explicitly named button.
            if let action = capture.action, collisions(action).isEmpty, capture.extensionName == nil { save(action, replacing: false) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in capture.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in capture.cancel() }
        .onDisappear { capture.cancel() }
    }

    private func toolbar(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(compact ? Metrics.keyboardGap : Metrics.keyboardToolbarGap)) {
            if !compact {
                Text("Choose a command to change its shortcut.")
                    .font(.system(size: metrics.length(Metrics.keyboardDetail)))
                    .foregroundStyle(Palette.muted)
            }
            HStack(spacing: metrics.length(Metrics.keyboardGap)) {
                Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                TextField("Find a command or shortcut", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityIdentifier("keyboard.search")
                if !query.isEmpty {
                    Button { query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Palette.muted).accessibilityLabel("Clear shortcut search")
                }
            }
            .font(.system(size: metrics.length(Metrics.settingsRowText)))
            .padding(metrics.length(Metrics.keyboardGap))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius)))
            .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius)).strokeBorder(searchFocused ? Palette.ink.opacity(0.35) : Palette.hairline, lineWidth: 1))
            HStack(alignment: .bottom, spacing: metrics.length(Metrics.keyboardToolbarGap)) {
                VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardSmallGap)) {
                    Text("Category").foregroundStyle(Palette.muted)
                    MigrationField(title: "Shortcut category", options: [(Optional<KeyGroup>.none, "All categories")] + KeyGroup.allCases.map { (Optional($0), $0.rawValue) },
                                   selection: $group, height: Metrics.settingsRow, showsTitle: false)
                }
                VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardSmallGap)) {
                    Text("Show").foregroundStyle(Palette.muted)
                    MigrationField(title: "Show shortcuts", options: KeyFilter.allCases.map { ($0, $0 == .all ? "All shortcuts" : $0.rawValue + ($0 == .modified ? " (\(modifiedCount))" : "")) },
                                   selection: $filter, height: Metrics.settingsRow, showsTitle: false)
                }
                .frame(maxWidth: metrics.length(Metrics.keyboardFilterWidth))
                Button { capture.cancel(); confirmingReset.toggle() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(height: metrics.length(Metrics.settingsRow))
                }
                .buttonStyle(KeyControlStyle(quiet: true))
                .disabled(modifiedCount == 0)
                .help("Reset all modified shortcuts…")
                .accessibilityLabel("Reset all modified shortcuts")
            }
            .font(.system(size: metrics.length(Metrics.keyboardDetail)))
            if !compact {
                let count = commands.count + references.count
                Text("\(count) \(count == 1 ? "command" : "commands")")
                    .font(.system(size: metrics.length(Metrics.keyboardDetail)))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.bottom, metrics.length(Metrics.keyboardGap))
    }
    private func heading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).fontWeight(.medium)
            Text("\(count)").foregroundStyle(Palette.muted)
        }
        .font(.system(size: metrics.length(Metrics.settingsHeading)))
        .foregroundStyle(Palette.ink)
        .padding(.top, metrics.length(Metrics.keyboardGap))
        .accessibilityAddTraits(.isHeader)
    }
    private var rule: some View { Rectangle().fill(Palette.hairline).frame(height: 1) }

    private func commandRow(_ command: KeyCommand) -> some View {
        let open = capture.action == command.action
        let keys = prefs.keyBindings.keys(command.action)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                searchFocused = false
                notice = ""
                if open { capture.cancel() } else { capture.begin(command.action) }
            } label: {
                HStack(alignment: .center, spacing: metrics.length(Metrics.keyboardGap)) {
                    VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardSmallGap)) {
                        Text(command.title).foregroundStyle(Palette.ink)
                        if prefs.keyBindings.changed(command.action) {
                            Text("Modified").font(.system(size: metrics.length(Metrics.keyboardDetail))).foregroundStyle(Palette.muted)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if open { keyBadge(capture.candidate?.label ?? "Press keys…", recording: true) }
                    else if keys.isEmpty { keyBadge("Add shortcut", recording: false) }
                    else {
                        HStack(spacing: metrics.length(Metrics.keyboardGap)) {
                            ForEach(keys, id: \.self) { keyBadge($0.label, recording: false) }
                        }
                    }
                }
                .font(.system(size: metrics.length(Metrics.settingsRowText)))
                .padding(.vertical, metrics.length(Metrics.keyboardRowPad))
                .padding(.horizontal, metrics.length(Metrics.keyboardGap))
                .contentShape(Rectangle())
            }
            .buttonStyle(KeyRowStyle())
            .accessibilityLabel("\(command.title), \(open ? (capture.candidate?.label ?? "Recording") : (keys.isEmpty ? "Unassigned" : keys.map(\.label).joined(separator: ", "))). Change shortcut")
            .accessibilityIdentifier("keyboard.command.\(command.id)")
            if open { editor(command) }
        }
        .background(open ? Palette.wash : Color.clear, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius)))
        .id(command.id)
    }
    private func keyBadge(_ title: String, recording: Bool) -> some View {
        Text(title).font(.system(size: metrics.length(Metrics.keyboardDetail), weight: .medium, design: .monospaced))
            .foregroundStyle(Palette.ink)
            .fixedSize()
            .padding(.horizontal, metrics.length(Metrics.keyboardKeyPad))
            .padding(.vertical, metrics.length(Metrics.keyboardSmallGap))
            .background(Palette.raised, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.keyboardKeyRadius)))
            .overlay(RoundedRectangle(cornerRadius: metrics.length(Metrics.keyboardKeyRadius)).strokeBorder(recording ? Palette.ink.opacity(0.4) : Palette.hairline, lineWidth: 1))
    }
    private func proposed(_ action: KeyAction) -> [KeyStroke] {
        capture.restoring ? action.command.defaults : capture.candidate.map { [$0] } ?? []
    }
    private func collisions(_ action: KeyAction) -> [KeyAction] { prefs.keyBindings.conflicts(proposed(action), excluding: action) }

    private func editor(_ command: KeyCommand) -> some View {
        let conflicts = collisions(command.action)
        return VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
            if !command.detail.isEmpty { Text(command.detail).foregroundStyle(Palette.muted) }
            Text(capture.restoring ? "Restore the default shortcuts for this command." : "Press a combination, then Save. Escape cancels; Tab leaves recording.")
                .foregroundStyle(Palette.muted)
            if let message = capture.message {
                Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Palette.danger)
            } else if !conflicts.isEmpty {
                Label("Already used by \(conflicts.map { $0.command.title }.joined(separator: ", ")). Replace removes this combination from those commands.", systemImage: "arrow.triangle.swap")
                    .foregroundStyle(Palette.ink)
            }
            if let name = capture.extensionName {
                Text("Also used by the extension “\(name)”. Escale will take this combination first.").foregroundStyle(Palette.ink)
            }
            if let caution = capture.candidate?.caution { Text(caution).foregroundStyle(Palette.muted) }
            if !capture.restoring, command.defaults.count > 1 {
                Text("Saving a new shortcut replaces this command’s alternatives.").foregroundStyle(Palette.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.length(Metrics.keyboardSmallGap)) { editorButtons(command, conflicts: conflicts) }
                VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardSmallGap)) { editorButtons(command, conflicts: conflicts) }
            }
        }
        .font(.system(size: metrics.length(Metrics.keyboardDetail)))
        .padding(.horizontal, metrics.length(Metrics.keyboardGap))
        .padding(.bottom, metrics.length(Metrics.keyboardGap))
        .fixedSize(horizontal: false, vertical: true)
    }
    @ViewBuilder private func editorButtons(_ command: KeyCommand, conflicts: [KeyAction]) -> some View {
        Button(conflicts.isEmpty && capture.extensionName == nil ? "Save" : "Replace shortcut") { save(command.action, replacing: true) }
            .buttonStyle(KeyControlStyle(primary: true))
            .disabled((capture.candidate == nil && !capture.restoring) || capture.message != nil)
            .accessibilityIdentifier("keyboard.save")
        Button("Cancel") { capture.cancel() }.buttonStyle(KeyControlStyle(quiet: true))
        if !prefs.keyBindings.keys(command.action).isEmpty {
            Button("Remove") { apply([], to: command.action, replacing: false) }.buttonStyle(KeyControlStyle(quiet: true))
        }
        if prefs.keyBindings.changed(command.action) {
            Button("Use default") {
                capture.restoring = true; capture.candidate = command.defaults.first; capture.message = nil; capture.extensionName = nil
                if collisions(command.action).isEmpty { apply(command.defaults, to: command.action, replacing: false) }
            }.buttonStyle(KeyControlStyle(quiet: true))
        }
    }
    private func save(_ action: KeyAction, replacing: Bool) {
        guard capture.message == nil, capture.candidate != nil || capture.restoring else { return }
        apply(proposed(action), to: action, replacing: replacing)
    }
    private func apply(_ keys: [KeyStroke], to action: KeyAction, replacing: Bool) {
        var bindings = prefs.keyBindings
        guard bindings.set(keys, for: action, replacing: replacing) else { return }
        prefs.keyBindings = bindings
        capture.cancel()
        notice = keys.isEmpty ? "\(action.command.title) is now unassigned." : "Saved · \(action.command.title)  \(keys.map(\.label).joined(separator: " / "))"
    }
    private var resetConfirmation: some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
            Text("Reset \(modifiedCount) modified commands to their defaults?")
            HStack {
                Button("Reset shortcuts") { prefs.keyBindings = KeyBindings(); confirmingReset = false; notice = "All shortcuts restored." }
                    .buttonStyle(KeyControlStyle(primary: true))
                Button("Keep changes") { confirmingReset = false }.buttonStyle(KeyControlStyle(quiet: true))
            }
        }
        .font(.system(size: metrics.length(Metrics.settingsRowText)))
        .padding(metrics.length(Metrics.keyboardGap))
        .background(Palette.wash, in: RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius)))
    }
    private func referenceRow(_ item: KeyReference) -> some View {
        VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.length(Metrics.keyboardToolbarGap)) {
                    Text(item.title).font(.system(size: metrics.length(Metrics.settingsRowText)))
                    Spacer(minLength: metrics.length(Metrics.keyboardGap))
                    keyBadge(item.keys, recording: false)
                }
                VStack(alignment: .leading, spacing: metrics.length(Metrics.keyboardGap)) {
                    Text(item.title).font(.system(size: metrics.length(Metrics.settingsRowText)))
                    keyBadge(item.keys, recording: false)
                }
            }
            Text(item.detail)
                .font(.system(size: metrics.length(Metrics.keyboardDetail)))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, metrics.length(Metrics.keyboardGap))
        .padding(.vertical, metrics.length(Metrics.keyboardRowPad))
        .accessibilityElement(children: .combine)
    }

}

/// Small settings controls share focus, pressed and hover treatment.
private struct KeyControlStyle: ButtonStyle {
    var chosen = false
    var primary = false
    var quiet = false
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, chosen: chosen, primary: primary, quiet: quiet) }
    private struct Face: View {
        let configuration: Configuration
        let chosen: Bool
        let primary: Bool
        let quiet: Bool
        @State private var hovering = false
        @SwiftUI.Environment(\.isEnabled) private var enabled
        @SwiftUI.Environment(\.chromeMetrics) private var metrics
        var body: some View {
            configuration.label
                .font(.system(size: metrics.length(Metrics.keyboardDetail), weight: chosen || primary ? .medium : .regular))
                .foregroundStyle(primary ? Palette.inverse : chosen || hovering ? Palette.ink : Palette.muted)
                .fixedSize()
                .padding(.horizontal, metrics.length(Metrics.keyboardGap))
                .padding(.vertical, metrics.length(Metrics.keyboardKeyPad))
                .background {
                    let shape = RoundedRectangle(cornerRadius: metrics.length(Metrics.settingsRowRadius))
                    if primary { shape.fill(Palette.ink.opacity(configuration.isPressed ? 0.75 : 1)) }
                    else if chosen { Chosen(radius: metrics.length(Metrics.settingsRowRadius)) }
                    else { shape.fill(configuration.isPressed || hovering ? Palette.hover : quiet ? Color.clear : Palette.wash) }
                }
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hovering = $0 && enabled }
        }
    }
}
private struct KeyRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }
    private struct Face: View {
        let configuration: Configuration
        @State private var hovering = false
        var body: some View {
            configuration.label.background(configuration.isPressed || hovering ? Palette.hover : Color.clear)
                .onHover { hovering = $0 }
        }
    }
}
