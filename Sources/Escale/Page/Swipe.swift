import Foundation

// Two fingers on a trackpad move the page, and nothing else.
//
// Escale once read a sideways swipe as back or forward. In a spreadsheet, a
// map or a wide table that same swipe is how you move around, and guessing
// which one was meant got it wrong often enough to lose people their place.
// The gesture is gone; ⌘[ and ⌘] and a mouse's side buttons go back and
// forward. What is left here is the page standing still at its edges.

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
}
