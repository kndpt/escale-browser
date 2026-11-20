import AppKit
import WebKit

// Tabs you aren't using, put to sleep.
//
// A page open in a tab keeps its whole content process — a hundred to three
// hundred megabytes, running its timers, holding its sockets — for as long as
// the tab exists. Twenty tabs is two or three gigabytes spent on the nineteen
// nobody is looking at. So a tab left alone for half an hour (or the delay
// chosen in Settings) gives its page back, and keeps what it takes to come back exactly where it was: its
// history, its scroll position, and a picture to show while the page is
// rebuilt underneath (see Tab.sleep).
//
// Some tabs never sleep, because waking them couldn't give back what they
// were doing: the one on screen, pinned tabs (those are put down by hand,
// with ⌘W), a tab playing sound, on a call, sending a download, holding its
// video out in the little window, or holding something typed and not sent.
//
// A heavy page can also be put to sleep by hand, from its tab's menu or with
// Sleep Other Tabs, without waiting for the clock. The same tabs stay awake,
// and one kept awake says why, since you asked for it.
//
// When macOS says memory is short, the delay shrinks: to five minutes on
// a warning, to nothing when it is critical — and then the pages go without
// a picture, since each would cost an image before anything is let go.
//
// The pictures are taken one at a time and kept within a budget, by
// `Pictures` (see Pictures.swift).

/// How long a tab waits before it sleeps, as offered in Settings.
enum SleepDelay: Int, CaseIterable, Identifiable {
    case quarter = 15, half = 30, hour = 60, twoHours = 120

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var title: String {
        switch self {
        case .quarter: return "15 min"
        case .half: return "30 min"
        case .hour: return "1 h"
        case .twoHours: return "2 h"
        }
    }

    /// As the help text says it.
    var phrase: String {
        switch self {
        case .quarter: return "a quarter of an hour"
        case .half: return "half an hour"
        case .hour: return "an hour"
        case .twoHours: return "two hours"
        }
    }

    /// Unset or unknown, half an hour, as before there was a choice.
    static func stored(_ minutes: Int?) -> SleepDelay {
        minutes.flatMap(SleepDelay.init) ?? .half
    }
}

extension Browser {
    /// How long a tab has to go without being looked at: the delay chosen in
    /// Settings, unless `sleep.after` in seconds says otherwise — for the
    /// bench and the measurements.
    static func sleepAfter(_ chosen: SleepDelay, bench: Double) -> TimeInterval {
        bench > 0 ? bench : chosen.seconds
    }

    /// Read on every tick, so a new choice applies without relaunching.
    var sleepAfter: TimeInterval {
        Browser.sleepAfter(prefs.sleepDelay, bench: Store.settings.double(forKey: "sleep.after"))
    }

    /// Started once, at launch. The tick runs only while tabs may sleep: a
    /// switched-off feature keeps no timer.
    func watchForSleep() {
        dozeSwitch = prefs.$sleepsTabs.removeDuplicates().sink { [weak self] on in
            MainActor.assumeIsolated { self?.doze(on) }
        }

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let event = self.pressure?.data else { return }
                self.pressed(critical: event.contains(.critical))
            }
        }
        source.resume()
        pressure = source
    }

    /// Every choice in Settings ticks once a minute; only the bench's short
    /// delays tick faster.
    private func doze(_ on: Bool) {
        dozing?.invalidate()
        dozing = nil
        guard on else { return }
        let every = min(60, max(5, sleepAfter / 4))
        let timer = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sleepIdle() }
        }
        timer.tolerance = every / 4
        RunLoop.main.add(timer, forMode: .common)
        dozing = timer
    }

    /// macOS said memory is short. Also what `bench idle warning|critical`
    /// runs, since a test can't make the system say it.
    func pressed(critical: Bool) {
        // The icons held in memory go too; the tabs keep theirs (see Icons.swift).
        if critical {
            Favicons.shared.shed()
            pictures.shed()
            github.relieve()
            for tab in tabs + parkedTabs { tab.visual.stop(); tab.area.stop(); tab.capture.close() }
        }
        sleepIdle(within: critical ? 0 : 5 * 60, pictured: !critical)
    }

    /// Every tab that has gone long enough without being looked at, the one
    /// left longest first. `pictured` false: without taking their picture.
    func sleepIdle(within given: TimeInterval? = nil, pictured: Bool = true) {
        guard prefs.sleepsTabs else { return }
        // With the window closed, no wait and no picture: nobody is looking
        // (see Away.swift). A tab kept awake then, still loading or playing,
        // goes at the next tick once it no longer is.
        let wait = away ? 0 : given ?? sleepAfter
        let pictured = pictured && !away
        let now = Date()
        // The rows of the other spaces too: parked is not the same as used.
        let idle = (tabs + parkedTabs)
            .filter { now.timeIntervalSince($0.touched) >= wait && awake(because: $0) == nil }
            .sorted { $0.touched < $1.touched }
        for tab in idle { self.sleep(tab, pictured: pictured) }
    }

    /// Why a tab has to stay awake — nil when nothing keeps it. The clock is
    /// the caller's business; this is everything else.
    func awake(because tab: Tab) -> String? {
        // With the window closed nothing is on screen (see Away.swift).
        let shown = !away
        if shown, panelTabs.contains(where: { $0.id == tab.id }) { return "on screen" }
        if shown, tab.pin != nil { return "pinned" }
        if tab.bench { return "a bench tab" }
        if tab.isBlank { return "blank" }
        if tab.asleep { return "already asleep" }
        guard let web = tab.built else { return "no page" }
        if tab.waking { return "still waking" } // (see Tab.waking)
        if tab.loading { return "still loading" }
        if tab.noisy { return "playing sound" }
        if tab.calls.open { return "collecting API calls" } // Calls.swift
        if tab.floating || floating == tab.id { return "its video is out" }
        if web.cameraCaptureState != .none || web.microphoneCaptureState != .none { return "on a call" }
        if downloads.isActive(on: web) { return "downloading" }
        // A sign-in window hands its answer back to the page that opened it.
        if shown, active?.opener == tab.id { return "the page on screen came from it" }
        return nil
    }

    /// Asks the page whether it holds anything typed, pictures it, then lets
    /// it go — looking again at each step, since each takes a moment and you
    /// may have gone back to the tab in the meantime. The picture waits its
    /// turn among the others (see Pictures.swift).
    func sleep(_ tab: Tab, pictured: Bool = true, done: ((String) -> Void)? = nil) {
        if let reason = awake(because: tab) {
            done?(reason)
            return
        }
        tab.unsaved { [weak self, weak tab] typed in
            guard let self, let tab else { return }
            if typed == true {
                done?("holding something typed")
                return
            }
            if typed == nil {
                done?("could not check for a draft")
                return
            }
            if let reason = self.awake(because: tab) {
                done?(reason)
                return
            }
            let asleep: (Data?) -> Void = { [weak self, weak tab] picture in
                guard let self, let tab else { return }
                if let reason = self.awake(because: tab) {
                    done?(reason)
                    return
                }
                tab.sleep(picture: picture)
                if picture != nil { self.pictures.keep(tab) }
                done?("asleep")
            }
            guard pictured else { return asleep(nil) }
            self.pictures.take(of: tab, when: { [weak self, weak tab] in
                guard let self, let tab else { return false }
                return self.awake(because: tab) == nil
            }, asleep)
        }
    }

    /// Sleep Tab, from a tab's menu: past the same checks as the clock's,
    /// then said, so a tab kept awake tells you why.
    func sleepByHand(_ tab: Tab) {
        sleep(tab) { [weak self] said in self?.announce(Browser.slept([said])) }
    }

    /// Sleep Tab from the keyboard. The tab on screen can't sleep, so first
    /// back to the one looked at before it, off screen, as Clear lands.
    func sleepActive() {
        guard let tab = active, let back = landing(leaving: tab) else { return }
        select(back)
        sleepByHand(tab)
    }

    /// Where Sleep Tab from the keyboard lands; nil when there is nowhere.
    func landing(leaving tab: Tab) -> Tab? {
        let shown = Set(panelTabs.map(\.id))
        return tabs.filter { $0.id != tab.id && !shown.contains($0.id) }.max { $0.touched < $1.touched }
    }

    /// What Sleep Other Tabs asks: this Space's row but `keep`, less the tabs
    /// holding no page, which have nothing to give back.
    func sleepers(but keep: Tab) -> [Tab] {
        tabs.filter { $0.id != keep.id && !$0.asleep && !$0.isBlank && $0.built != nil }
    }

    /// One line once every tab has answered, not one per tab.
    func sleepOthers(but keep: Tab) {
        let others = sleepers(but: keep)
        var said: [String] = []
        for tab in others {
            sleep(tab) { [weak self] reason in
                said.append(reason)
                if said.count == others.count { self?.announce(Browser.slept(said)) }
            }
        }
    }

    /// What putting tabs to sleep by hand says, from each tab's answer to
    /// `sleep`: how many went and, once each, what kept the others awake.
    static func slept(_ answers: [String]) -> String {
        let kept = answers.filter { $0 != "asleep" }
        if answers.count == 1 { return kept.first.map { "Kept awake: \($0)" } ?? "Tab asleep" }
        var why: [String] = []
        for reason in kept where !why.contains(reason) { why.append(reason) }
        let went = answers.count - kept.count
        let asleep = went == 0 ? "No tab asleep" : went == 1 ? "1 tab asleep" : "\(went) tabs asleep"
        return kept.isEmpty ? asleep : "\(asleep), \(kept.count) kept awake: \(why.joined(separator: ", "))"
    }
}
