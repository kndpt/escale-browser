import AppKit
import SwiftUI
import WebKit

// The extensions in the bar: the puzzle button and its list, and the pinned
// ones beside it. What a press does is the controller's (Extensions.press);
// here is only how they look and where a popup is anchored.

/// A weak hold on an NSView, for the anchors.
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

/// The extensions, behind one puzzle button — a list to press them from,
/// pin them out of, reload or remove them. The pinned ones also sit in the
/// row beside it, the way Chrome does it. The button is there with nothing
/// installed too: it is where someone coming from another browser looks for
/// extensions. Nothing at all below macOS 15.4.
struct ExtensionSlot: View {
    /// The Space on screen, given by the bar. Read from `Extensions.shared`,
    /// the owner was looked up only when SwiftUI ran this body, and it does
    /// not run it again while the inputs are the same: the slot kept the
    /// Space it was built in. Rebuilt by a layout change in a Space without
    /// extensions, it stayed empty back in the one with them until a
    /// relaunch.
    let space: UUID
    /// The side the list opens toward: down from the top row, out to the
    /// right from the sidebar.
    var edge: Edge = .bottom
    /// The extensions the Space brought from another browser or Space, given
    /// by the bar for the same reason as `space`.
    var planned: [PlannedExtension] = []

    var body: some View {
        if #available(macOS 15.4, *) {
            ExtensionButtons(extensions: .forSpace(space), edge: edge, planned: planned)
        }
    }
}

@available(macOS 15.4, *)
private struct ExtensionButtons: View {
    @ObservedObject var extensions: Extensions
    let edge: Edge
    let planned: [PlannedExtension]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(extensions.buttons.filter(\.pinned)) { button in
                ActionButton(button: button) { extensions.press(button.id) }
                    .background(Anchor(id: button.id, owner: extensions))
                    .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
            }
            Door(
                icon: "puzzlepiece.extension", on: extensions.menuOpen,
                help: planned.isEmpty ? "Extensions" : "Extensions · \(planned.count) to reinstall",
                count: planned.count
            ) {
                extensions.menuOpen.toggle()
            }
            .background(Anchor(id: Extensions.menuAnchor, owner: extensions))
            .popover(isPresented: $extensions.menuOpen, arrowEdge: edge) {
                ExtensionMenu(extensions: extensions, planned: planned)
            }
        }
    }

    private struct ActionButton: View {
        let button: Extensions.Button
        let press: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: press) {
                ExtensionIcon(button: button, size: 15)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(hovering ? Palette.hover : .clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(button.label)
        }
    }

    /// A real view under the button, so the popup has something to hang from.
    private struct Anchor: NSViewRepresentable {
        let id: String
        let owner: Extensions
        func makeNSView(context: Context) -> ExtensionAnchor {
            let view = ExtensionAnchor()
            updateNSView(view, context: context)
            return view
        }
        func updateNSView(_ view: ExtensionAnchor, context: Context) {
            view.id = id
            view.space = owner.space
            owner.anchors[id] = WeakView(view)
        }
    }
}

/// The view a button of the slot hangs its popup from. It says which button
/// and whose Space it is, so the bench can read what the bar really shows.
final class ExtensionAnchor: NSView {
    var id = ""
    var space: UUID?
}

/// An extension's icon with its badge in the corner.
@available(macOS 15.4, *)
private struct ExtensionIcon: View {
    let button: Extensions.Button
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = button.icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                } else {
                    // Its initial, rather than a puzzle piece that would
                    // pass for the button the list opens from.
                    Text(button.name.first.map { String($0).uppercased() } ?? "?")
                        .font(.system(size: size * 0.62, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Palette.wash))
                }
            }
            .frame(width: size + 4, height: size + 4)
            .opacity(button.enabled ? 1 : 0.4)
            if !button.badge.isEmpty {
                Text(button.badge)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(Palette.inverse)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 12, minHeight: 11)
                    .background(Palette.ink, in: Capsule())
                    .fixedSize()
                    .offset(x: 5, y: 3)
            }
        }
    }
}

/// What a right-click on an extension offers, in the row and in the list.
@available(macOS 15.4, *)
private struct ExtensionActions: View {
    let id: String
    let name: String
    let extensions: Extensions

    var body: some View {
        let pinned = extensions.installed.first { $0.id == id }?.pinned ?? false
        SwiftUI.Button(pinned ? "Unpin" : "Pin to Toolbar") { extensions.setPinned(id, !pinned) }
        if extensions.contexts[id]?.optionsPageURL != nil {
            SwiftUI.Button("Options…") { extensions.openOptions(id) }
        }
        SwiftUI.Button("Reload") { extensions.reload(id) }
        Divider()
        SwiftUI.Button("Remove “\(name)”…") { ExtensionActions.confirmRemove(id, name: name, extensions) }
    }

    static func confirmRemove(_ id: String, name: String, _ extensions: Extensions) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "Its settings and data go with it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { extensions.remove(id) }
    }
}

/// The list, drawn off screen — for the bench, which can't keep a popover
/// open in a browser that isn't in front.
@available(macOS 15.4, *)
@MainActor
func extensionMenuPicture() -> NSBitmapImageRep? {
    // A popover's material has nothing to show through off screen.
    let extensions = Extensions.shared
    let planned = extensions.browser?.plannedExtensions ?? []
    let host = NSHostingView(rootView: ExtensionMenu(extensions: extensions, planned: planned).background(Palette.panel))
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.appearance = NSApp.effectiveAppearance
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: picture)
    return picture
}

/// The list behind the puzzle button: the extensions left to reinstall,
/// every running extension with a pin for each, and the way to Settings.
/// With neither, a word on what extensions are here and the way to the store.
@available(macOS 15.4, *)
private struct ExtensionMenu: View {
    @ObservedObject var extensions: Extensions
    let planned: [PlannedExtension]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let buttons = extensions.buttons
            if let whose = extensions.whose {
                Text(extensions.shared ? "Every Space" : whose)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
            }
            if !planned.isEmpty {
                // Bounded like the list below: an import can bring hundreds.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("To reinstall")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("Imported with this Space. Reinstall them to use them here.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.bottom, 4)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(planned.enumerated()), id: \.offset) { _, item in
                                PlannedRow(item: item, extensions: extensions) { extensions.menuOpen = false }
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                if !extensions.installed.isEmpty { Divider().overlay(Palette.hairline) }
            }
            if extensions.installed.isEmpty {
                if planned.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No extensions yet")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Palette.ink)
                        Text("Escale runs extensions from the Chrome Web Store. Find one there and press Add to Escale on its page.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Palette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Pill("Open the Chrome Web Store", filled: true) {
                            extensions.menuOpen = false
                            extensions.browser?.open(Browser.webStore, foreground: true)
                        }
                        .padding(.top, 4)
                    }
                    .padding(14)
                }
            } else if buttons.isEmpty {
                Text("None of your extensions is on")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.muted)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(buttons) { button in
                            Row(button: button, extensions: extensions)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.hairline)
            VStack(spacing: 1) {
                Foot("storefront", "Chrome Web Store…") {
                    extensions.menuOpen = false
                    extensions.browser?.open(Browser.webStore, foreground: true)
                }
                Foot("folder", "Load Unpacked…") {
                    extensions.menuOpen = false
                    DispatchQueue.main.async { extensions.installFolder() }
                }
                Foot("gearshape", "Manage Extensions…") {
                    extensions.menuOpen = false
                    Store.settings.set("extensions", forKey: "settings.page")
                    extensions.browser?.tuning = true
                }
            }
            .padding(6)
        }
        .frame(width: 280)
        // The popover's own material shows through (Glass.swift).
        .popoverGround()
    }

    private struct Row: View {
        let button: Extensions.Button
        @ObservedObject var extensions: Extensions
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 9) {
                ExtensionIcon(button: button, size: 16)
                Text(button.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(button.enabled ? Palette.ink : Palette.muted)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hovering, extensions.installed.first(where: { $0.id == button.id })?.source != nil {
                    Tool(symbol: "arrow.clockwise", help: "Reload from its folder") { extensions.reload(button.id) }
                }
                if hovering || button.pinned {
                    Tool(symbol: button.pinned ? "pin.fill" : "pin", help: button.pinned ? "Unpin" : "Pin to toolbar", on: button.pinned) {
                        extensions.setPinned(button.id, !button.pinned)
                    }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                // The list goes first; the popup, if there is one, then
                // hangs from the puzzle button it came out of.
                extensions.menuOpen = false
                let id = button.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { extensions.press(id) }
            }
            .onHover { hovering = $0 }
            .help(button.label)
            .contextMenu { ExtensionActions(id: button.id, name: button.name, extensions: extensions) }
        }
    }

    /// A small icon button at the end of a row.
    private struct Tool: View {
        let symbol: String
        let help: String
        var on = false
        let act: () -> Void
        @State private var hovering = false

        var body: some View {
            SwiftUI.Button(action: act) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(on || hovering ? Palette.ink : Palette.muted)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Palette.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }

    private struct Foot: View {
        let symbol: String
        let title: String
        let act: () -> Void
        @State private var hovering = false

        init(_ symbol: String, _ title: String, act: @escaping () -> Void) {
            self.symbol = symbol
            self.title = title
            self.act = act
        }

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Palette.muted).frame(width: 14)
                Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Palette.wash : .clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: act)
            .onHover { hovering = $0 }
        }
    }
}
