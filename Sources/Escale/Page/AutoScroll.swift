// Scrolling with the middle button, as on Windows: a click of the wheel on
// a page (not on a link, which it still opens in a new tab) leaves a mark
// where it was, and the page scrolls towards the pointer, faster the
// further away it is. Another click, Escape or the wheel stops it; held down
// and dragged, it stops when the button is let go.
//
// On unless turned off in Settings › Web Pages. Done in the page, which knows
// what is under the pointer and which part of it scrolls.

enum AutoScroll {
    /// Settings › Web Pages › Scroll with the middle button.
    @MainActor static var on = false

    /// For a page already up when it is turned off. A scroll under way stops
    /// there and then — a flag alone left its frame loop running until the
    /// next click — and the page keeps none of the script's listeners, so
    /// turning it on again puts the script back whole.
    static let off = "window.__escaleAutoScroll && window.__escaleAutoScroll();"

    static let script = Bundled.script("auto-scroll.js")
}
