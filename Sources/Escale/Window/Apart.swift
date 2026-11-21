import AppKit
import Combine

// A tab dragged out of the window goes on in a window of its own: the page and
// its title, nothing else. Escale has one browser window, so this is not a
// second browser: the tab leaves the row but stays the Browser's, with its
// space, its delegate and its place in the saved session (writeSession). Its
// web view simply changes windows, as the floating video's does (Float.swift),
// and closing the window puts the tab back in the row, page untouched.

@MainActor
final class Apart: NSObject, NSWindowDelegate {
    /// Each tab out, with the window that holds it.
    private var out: [Tab.ID: (tab: Tab, window: NSWindow, title: AnyCancellable)] = [:]
    /// Asked when a window closes: the tab goes home.
    var onClose: ((Tab) -> Void)?
    /// A tab closed out here, which no row change announces (Extensions.swift).
    let dropped = PassthroughSubject<Void, Never>()

    var tabs: [Tab] { out.values.map(\.tab) }

    func holds(_ tab: Tab) -> Bool { out[tab.id] != nil }

    /// The window, or a sheet on it (a page's dialog or file picker).
    func holds(_ window: NSWindow?) -> Bool {
        let window = window?.sheetParent ?? window
        return out.values.contains { $0.window === window }
    }

    /// A window under the pointer, the page's size, the page moved into it.
    func open(_ tab: Tab, at point: NSPoint, size: NSSize) {
        guard out[tab.id] == nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: point.x - 40, y: point.y - size.height + 20, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 320, height: 200)
        window.backgroundColor = Palette.NS.ground
        window.tabbingMode = .disallowed
        window.delegate = self
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        // Held at once, so nothing sees the tab gone between the row and here;
        // the page moves a turn later, once the stage has let it go.
        out[tab.id] = (tab, window, AnyCancellable {})
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, out[tab.id]?.window === window else { return }
            show(tab, in: window)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// A tab replaced by another (Browser.replace): the new page takes the window.
    func swap(_ old: Tab, for fresh: Tab) {
        guard let entry = out.removeValue(forKey: old.id) else { return }
        entry.window.contentView?.subviews.forEach { $0.removeFromSuperview() }
        show(fresh, in: entry.window)
    }

    private func show(_ tab: Tab, in window: NSWindow) {
        guard let ground = window.contentView else { return }
        let page = tab.web
        page.removeFromSuperview()
        page.autoresizingMask = [.width, .height]
        page.frame = ground.bounds
        page.alphaValue = 1
        ground.addSubview(page)
        let title = tab.$title.sink { [weak window, weak tab] _ in
            DispatchQueue.main.async { if let tab { window?.title = tab.label } }
        }
        out[tab.id] = (tab, window, title)
    }

    /// The window goes without asking for the tab back: the tab was closed.
    func drop(_ tab: Tab) {
        guard let entry = out.removeValue(forKey: tab.id) else { return }
        entry.window.delegate = nil
        entry.window.close()
        dropped.send()
    }

    /// Chosen from ⌘K: its window comes forward.
    func front(_ tab: Tab) { out[tab.id]?.window.makeKeyAndOrderFront(nil) }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = out.first(where: { $0.value.window === window }) else { return }
        out[entry.key] = nil
        window.delegate = nil
        onClose?(entry.value.tab)
    }
}
