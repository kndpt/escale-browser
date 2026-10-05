// Tab and bookmark menus enter the same routing draft, without navigating or
// waking the source page. Adding an address appends to unfinished work and
// opens Settings at that rule; it does not activate a route before Save.
import SwiftUI

struct LinkRouteMenu: View {
    let browser: Browser
    let address: URL?
    let space: UUID

    var body: some View {
        if let address, LinkRule.address(address.absoluteString) != nil {
            Button { browser.editLinkRoute(address, destination: space) } label: {
                Label("Open Links in a Space…", systemImage: "arrow.triangle.branch")
            }
            .disabled(browser.linkRoutes.draft.rules.count >= LinkRule.limit || browser.spaces.isEmpty)
        }
    }
}

extension Browser {
    func editLinkRoute(_ address: URL, destination: UUID) {
        guard LinkRule.address(address.absoluteString) != nil,
              let target = spaces.first(where: { $0.id == destination }) ?? spaces.first,
              linkRoutes.draft.add(destination: target.id, address: address.absoluteString) else { return }
        managing = false; bookmarking = false; bookmarksOpen = false
        Store.settings.set("routing", forKey: "settings.page")
        tuning = true
    }
}
