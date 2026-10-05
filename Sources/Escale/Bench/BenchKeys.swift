// A scripted test world takes its keys from the script alone. `fresh.sh` opens
// it in front and every `hit … live` click brings it back there, so whatever
// the person at this Mac types meanwhile lands in it. Typing in another app
// during tab_search_button.py filtered every tab out of the open switcher
// (`typed` "us", then "e "), closed it with a Return, or turned it into the
// GitHub search with a Tab.
//
// Keys the bench presses are made in this process, and their CGEvent carries
// its pid; the keyboard's carry 0, and another process's its own pid. On a
// test run, while the bench listens, those are dropped before any view or
// shortcut sees them, and counted so a scenario can tell. The order AppKit
// calls local monitors in is not that of their adding: the window's shortcuts
// (App.watchKeys), added after this one, saw an outside ⌘T first and opened a
// tab. So the shortcuts' monitor asks `foreign` before
// anything else, and this monitor catches what it does not watch (key-up).
// Both stand aside while the bench is off. The pointer is not filtered.
import AppKit

@MainActor
enum BenchKeys {
    /// Keys from outside this process dropped while the bench listened.
    private(set) static var ignored = 0
    private static var monitor: Any?

    /// On a test run only, as the app finishes launching.
    static func install() {
        guard Store.testing, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            MainActor.assumeIsolated { foreign(event) } ? nil : event
        }
    }

    /// True, and counted, for a key from outside this process while the
    /// bench listens on a test run: to be dropped by whoever sees it first.
    static func foreign(_ event: NSEvent) -> Bool {
        guard Store.testing, Bench.shared.running,
              let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID),
              source != Int64(getpid()) else { return false }
        ignored += 1
        return true
    }
}
