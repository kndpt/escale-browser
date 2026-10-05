import Foundation

// Two fingers sideways means back, or forward.
//
// WebKit has a swipe of its own, and it drags the whole page across the window
// with a picture of the last one behind it. This is the other kind: a disc
// comes in from the edge you are pulling from, and past a certain point it is
// armed. Let go then, and the page simply goes back. Let go before, and it
// slips out again. Nothing slides, nothing is kept in memory to slide.
//
// The one hard question is whether a sideways swipe belongs to the page — a
// carousel, a wide table, a map — or is free to mean something. The page is
// asked, on every sideways wheel event, whether anything under the pointer
// could scroll that way. The answer arrives a frame or two after the gesture
// starts, which is before there is anything to show.

enum Swipe {
    /// No rubber-banding. Pulling past the top of a page showed a band of
    /// blank ground above it, and nobody who came from Chrome read that as
    /// anything but a fault. Setting it on the root turns the bounce off in
    /// WebKit; inner scrollers keep chaining to the page as they always did.
    ///
    /// Only the vertical half, and without `!important`: a page that sets its
    /// own `overscroll-behavior` — Cosmos does, to keep its board from
    /// chaining into a browser gesture — is a page that already means
    /// something by it. `!important` on both axes overrode that outright,
    /// and on at least that one site, forcing `none` on top of the page's own
    /// `contain` didn't just stop the bounce — it stopped the scroll
    /// underneath it too. This still comes first on the page (`atDocumentStart`,
    /// nothing has been styled yet), so an ordinary page with no opinion of
    /// its own is calmed exactly as before; a page that sets its own rule
    /// later in the cascade wins the way any later, unremarkable rule would.
    static let calm = Bundled.script("swipe-calm.js")

    /// Whether a sideways swipe here would scroll something. Said once per
    /// change of mind, and at most ten times a second, so the page is never
    /// made to shout.
    static let watch = Bundled.script("swipe-watch.js")
}

/// Where a sideways swipe has got to, for the disc that shows it.
struct Pull: Equatable {
    /// Pulling from the left edge, to go back; otherwise from the right.
    var back: Bool
    /// How far the fingers have come, in points, before any damping.
    var travel: CGFloat
    /// Far enough that letting go will do it.
    var armed: Bool
    /// Let go while armed: the page is on its way, and the disc leaves.
    var going: Bool
}
