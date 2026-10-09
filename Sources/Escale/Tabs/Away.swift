import AppKit

// The window closed, the app still running, as in Safari or Chrome (see
// Links.applicationShouldTerminateAfterLastWindowClosed).
//
// Nobody can see a page then, and yet it runs: five busy pages behind a
// closed window still took six seconds of CPU every thirty. So closing the
// window puts every tab to sleep at once, as the sleep policy does after half
// an hour (Sleep.swift), without the pictures nobody would look at. What a
// wake couldn't give back stays awake, as always: sound, a call, a download,
// a draft. Nothing is on screen then, so neither the tab that was nor a pin
// is kept for it. The window back, the pages it shows wake, as after a launch.

extension Browser {
    /// Closed, not minimised: AppKit keeps the window, out of sight.
    var away: Bool {
        guard let window = Links.window else { return false }
        return !window.isVisible && !window.isMiniaturized
    }

    /// Started once, at launch. The browser lives as long as the app, so the
    /// observers are never removed.
    func watchWindow() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard note.object as? NSWindow === Links.window else { return }
            // Once AppKit has taken it off screen, `away` says so.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.away, self.prefs.sleepsTabs else { return }
                    for tab in self.tabs + self.parkedTabs { self.sleep(tab, pictured: false) }
                }
            }
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard note.object as? NSWindow === Links.window else { return }
            MainActor.assumeIsolated {
                guard let self, self.panelTabs.contains(where: \.asleep) else { return }
                self.wakePanels()
            }
        }
    }
}
