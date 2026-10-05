import AppKit

// The pictures sleeping tabs keep, and the taking of them.
//
// A tab put to sleep keeps a picture of its page, shown over the stage for
// the moment the page takes to come back (see Tab.wake). Taking one is not
// free: WebKit draws the page into an image, and the app makes a JPEG of it.
// The idle pass used to ask every tab it found at once — twenty tabs, twenty
// pictures under way together — and every picture stayed for as long as its
// tab slept, 270 to 410 KB each at the screen's two pixels per point.
//
// So: one picture under way at a time, the others waiting their turn, and
// one whose tab no longer has to sleep by then is not taken. A picture is
// taken at one pixel per point — a quarter of the pixels; the page comes
// back sharp underneath a moment later. Pictures kept weigh 8 MB at most
// together, about a hundred tabs' worth; past that the pictures of the tabs
// asleep longest go, and those tabs wake on their page without one, as a tab
// restored from the last session does. Under critical memory pressure no
// picture is taken — the pages go at once rather than after one more image
// each — and the pictures already kept go too (see Browser.pressed).

@MainActor
final class Pictures {
    /// What all kept pictures may weigh together. `sleep.pictures`, in bytes,
    /// changes it for the bench, the way `sleep.after` does the half hour.
    static var budget: Int {
        let set = Store.settings.integer(forKey: "sleep.pictures")
        return set > 0 ? set : 8_000_000
    }
    /// Pictures under way at once.
    static let atOnce = 1

    /// A tab waiting for its picture, and everyone waiting on it.
    private struct Ask {
        weak var tab: Tab?
        let still: () -> Bool
        var done: [(Data?) -> Void]
    }
    private var waiting: [Ask] = []
    private var taking = 0

    /// Tabs holding a picture, in the order they went to sleep.
    private struct Kept { weak var tab: Tab? }
    private var kept: [Kept] = []

    /// For `bench caches`: the most ever under way at once, and how many
    /// were taken.
    private var peak = 0
    private var taken = 0

    /// A picture of the tab's page, when its turn comes, if `still` says
    /// then that it is wanted; nil otherwise. Asked twice for the same tab
    /// before its turn, it is taken once and handed to both.
    func take(of tab: Tab, when still: @escaping () -> Bool, _ done: @escaping (Data?) -> Void) {
        if let index = waiting.firstIndex(where: { $0.tab === tab }) {
            waiting[index].done.append(done)
            return
        }
        waiting.append(Ask(tab: tab, still: still, done: [done]))
        next()
    }

    private func next() {
        while taking < Pictures.atOnce, !waiting.isEmpty {
            let ask = waiting.removeFirst()
            guard let tab = ask.tab, ask.still() else {
                ask.done.forEach { $0(nil) }
                continue
            }
            taking += 1
            peak = max(peak, taking)
            tab.snapshot { [weak self] picture in
                guard let self else { return }
                taking -= 1
                taken += 1
                ask.done.forEach { $0(picture) }
                next()
            }
        }
    }

    /// The tab has just gone to sleep holding a picture: counted in, and the
    /// pictures of the tabs asleep longest let go past the budget.
    func keep(_ tab: Tab) {
        kept.removeAll { $0.tab == nil || $0.tab === tab || ($0.tab?.pictureBytes ?? 0) == 0 }
        kept.append(Kept(tab: tab))
        var total = kept.reduce(0) { $0 + ($1.tab?.pictureBytes ?? 0) }
        while total > Pictures.budget, !kept.isEmpty {
            let oldest = kept.removeFirst()
            total -= oldest.tab?.pictureBytes ?? 0
            oldest.tab?.forgetPicture()
        }
    }

    /// Critical memory pressure: every tab waiting for a picture goes to
    /// sleep without one, and the pictures kept go.
    func shed() {
        let asked = waiting
        waiting = []
        for ask in asked { ask.done.forEach { $0(nil) } }
        for entry in kept { entry.tab?.forgetPicture() }
        kept = []
    }

    var counts: [String: Int] {
        ["taking": taking, "waiting": waiting.count, "peak": peak, "taken": taken]
    }
}
