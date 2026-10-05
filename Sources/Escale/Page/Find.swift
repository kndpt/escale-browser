// Find owns the query and guards WebKit's asynchronous answers. Its field asks
// for keyboard focus after mounting, because a split can rearrange native
// page views in the same turn that the search bar is opened.
import SwiftUI
import WebKit

/// What is being looked for on the page, and whether the page holds it. The
/// bar's text changes with every key, and each asks the page again; held in
/// `Browser`, every key would publish the whole window. The bar observes this
/// alone; `Browser` keeps whether the bar is up (`finding`), which the menu
/// reads, and opening and closing it.
///
/// It sees no `Browser`, only the page on screen (`page`). An answer is taken
/// only while it still answers the question on screen: the same text, on the
/// same page. One that arrived after a switch of tab, a new page or a new key
/// would mark the page on screen as missing a word it was never asked for.
/// One per window, for its life; no timer, no subscription, no work while
/// nothing is typed.
@MainActor
final class Find: ObservableObject {
    @Published var needle = "" { didSet { look(forward: true) } }
    /// Set when the page doesn't hold what was asked for.
    @Published private(set) var missed = false
    /// Bumped whenever the caret should go back into the bar.
    @Published private(set) var focus = 0

    /// The page on screen, if one is built: asking must never build one. The
    /// bar follows you to a blank tab, and its text is written again on the
    /// way; asking for a page then built one for the blank tab, a content
    /// process and all, and so did closing the bar there.
    private let page: () -> WKWebView?

    init(page: @escaping () -> WKWebView?) {
        self.page = page
    }

    func askFocus() { focus += 1 }

    /// The bar put away: nothing asked, nothing missed.
    func clear() {
        needle = ""
        missed = false
    }

    func look(forward: Bool) {
        guard let web = page(), !needle.isEmpty else {
            missed = false
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        let asked = needle
        web.find(asked, configuration: configuration) { [weak self, weak web] result in
            MainActor.assumeIsolated {
                guard let self, let web, web === self.page(), self.needle == asked else { return }
                self.missed = !result.matchFound
            }
        }
    }
}

/// Looking for a word on the page. A pill in the top corner, the same white and
/// hairline as everything else that floats, and gone the moment it isn't wanted.
struct FindBar: View {
    /// For closing; what is looked for is `find`'s.
    let browser: Browser
    @ObservedObject var find: Find

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if find.needle.isEmpty {
                    Text("Find on page")
                        .foregroundStyle(Palette.ink.opacity(0.3))
                }
                TextField("", text: $find.needle)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .focused($focused)
                    .onSubmit { find.look(forward: true) }
            }
            .font(.system(size: 12.5))
            .frame(width: 160)

            step("chevron.up") { find.look(forward: false) }
            step("chevron.down") { find.look(forward: true) }
            step("xmark") { browser.closeFind() }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glass(.chip, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Palette.danger.opacity(find.missed ? 0.55 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .padding(.top, 12)
        .padding(.trailing, 14)
        .animation(Motion.quick, value: find.missed)
        .onAppear { takeFocus() }
        .onChange(of: find.focus) { _, _ in takeFocus() }
    }

    private func takeFocus() {
        focused = false
        DispatchQueue.main.async {
            if browser.finding { focused = true }
        }
    }

    private func step(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
