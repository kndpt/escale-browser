// A tab silenced from its speaker, the way every other browser does it: one
// click on the mark mutes the page and a second gives its sound back.
//
// The page keeps playing; only its output is cut, so nothing is lost to a
// pause the page may not resume. WebKit mutes a whole page only through a name
// outside its public framework, so it is asked first and a tab without it
// keeps a speaker that does nothing. That name sets every muted flag at once,
// so the camera and microphone flags are read and written back as they were.
// The choice lives on the tab, not the view: a tab that sleeps and wakes, or
// goes to another page, stays quiet until it is clicked again.
import SwiftUI
import WebKit

extension Tab {
    /// Mute or unmute the page from its tab's speaker.
    func toggleMute() {
        guard Mute.available else { return }
        muted.toggle()
        if let built { Mute.apply(muted, to: built) }
    }
}

enum Mute {
    private static let setter = NSSelectorFromString("_setPageMuted:")
    private static let state = "_mediaMutedState"
    /// `_WKMediaAudioMuted`; the other bits are capture.
    private static let audio: UInt = 1

    static let available = WKWebView.instancesRespond(to: setter)
        && WKWebView.instancesRespond(to: NSSelectorFromString(state))

    static func apply(_ on: Bool, to web: WKWebView) {
        guard available, let method = web.method(for: setter) else { return }
        let flags = (web.value(forKey: state) as? UInt) ?? 0
        let next = on ? flags | audio : flags & ~audio
        guard next != flags else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method, to: Setter.self)(web, setter, next)
    }
}

/// The speaker at the start of a tab's row: which tab the sound comes from,
/// and the switch that silences it. ⌘⇧M stops it instead.
struct Speaker: View {
    @ObservedObject var tab: Tab
    @SwiftUI.Environment(\.chromeMetrics) private var metrics

    var body: some View {
        if tab.noisy || tab.muted {
            Button { tab.toggleMute() } label: {
                Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: metrics.length(8)))
                    .foregroundStyle(Palette.muted)
                    // Bigger to hit than to see, like the cross.
                    .frame(width: metrics.length(12), height: metrics.length(16))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.muted ? "Unmute Tab" : "Mute Tab")
            .transition(.opacity)
        }
    }
}
