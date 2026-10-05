import AppKit

// The window's side of passwords: the offer to keep one a page has just sent,
// the accounts hanging from the sign-in box the caret is in, and the list in
// the Passwords panel. The keychain itself is Vault's; this holds what is
// shown of it, and for no longer than it is shown.
//
// Passwords are not kept in memory for the window's life: the list is read
// when the panel opens and let go of when it closes (`show` and `hide`, called
// by the panel's switch, `Browser.managing`). An offer is held until it is answered,
// a list of accounts until the caret leaves the box.
//
// Held in `Browser`, each of these would publish the whole window — the list
// of accounts comes and goes as the caret moves between a form's boxes — and
// every view observing `Browser` would be asked again; the list, the offer
// and the panel observe this alone.
//
// It sees no `Browser`: it says things through `say`, and finds a tab by its
// id through `tab`. Which tab a box belongs to, whether filling is on and
// which site a page is on stay the window's to decide (see Browser.prepare).
// One per window, for the window's life; its only timer is the 0.2 s before
// a list of accounts is taken down, cancelled by the next event.

@MainActor
final class Logins: ObservableObject {
    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    @Published private(set) var offering: Offer?
    private var parkedOffers: [UUID: Offer] = [:]

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    @Published private(set) var suggesting: Suggesting?

    struct Suggesting: Equatable {
        let tab: Tab.ID
        let spot: CGRect
        let logins: [Login]
    }
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    private var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    private var lowering: DispatchWorkItem?

    /// Where the caret is, while a list should hang from it.
    private struct Look: Equatable {
        let tab: Tab.ID
        let spot: CGRect
        let host: String
        let space: UUID
    }
    private var wanted: Look?
    private var reading = false
    /// One keychain read at a time, off the main thread: the first of a run
    /// can stop to ask macOS for permission and wait for as long as the answer
    /// takes, which on the main thread would hold the whole window still.
    private static let keychain = DispatchQueue(label: "escale.logins.lookup", qos: .userInitiated)

    // The list of what is kept: read only while the panel shows it.

    @Published private(set) var saved: [Login] = []
    @Published var hunting = ""
    private var showing = false

    struct SiteRow {
        let host: String
        let logins: [Login]
    }

    /// Something to say, on the line that rises from the bottom.
    private let say: (String) -> Void
    /// A tab of the window by its id; nil for none, or one gone.
    private let tab: (Tab.ID?) -> Tab?
    /// What the keychain holds, read for the panel: Vault's, but for the
    /// tests of what is kept when, which have no keychain to read.
    private let read: () -> [Login]
    /// The accounts kept for a site, read off the main thread (see `caret`).
    private let lookup: (String, UUID) -> [Login]

    init(
        say: @escaping (String) -> Void,
        tab: @escaping (Tab.ID?) -> Tab?,
        read: @escaping () -> [Login] = { Vault.all() },
        lookup: @escaping (String, UUID) -> [Login] = { Vault.logins(matching: $0, space: $1) }
    ) {
        self.say = say
        self.tab = tab
        self.read = read
        self.lookup = lookup
    }

    // MARK: - the offer

    /// A page sent a name and password: offered a place in the keychain,
    /// unless it is already there as it is.
    func sent(host: String, user: String, password: String, space: UUID) {
        let known = Vault.logins(for: host, space: space)
        // Nothing to ask about one that is already known.
        if let same = known.first(where: { $0.user == user && $0.password == password }) {
            Vault.touch(same)
            return
        }
        let offer = Offer(
            login: Login(host: host, user: user, password: password, used: nil, space: space),
            changed: known.contains { $0.user == user }
        )
        if space == Spaces.current {
            guard offering != offer else { return }
            offering = offer
        } else {
            parkedOffers[space] = offer
        }
    }

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        guard Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), space: login.space) else {
            say("The keychain refused it")
            return
        }
        relist()
        say(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
    }

    func dropOffer() { offering = nil }

    func enter(_ space: UUID) {
        if let offer = offering { parkedOffers[offer.login.space] = offer }
        offering = parkedOffers.removeValue(forKey: space)
        dropChoice()
        relist()
    }

    func erase(_ space: UUID) {
        parkedOffers[space] = nil
        if offering?.login.space == space { offering = nil }
    }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host, space: offer.login.space)
        offering = nil
        say("Never for \(offer.login.host)")
    }

    // MARK: - the accounts under a sign-in box

    /// The caret went into a sign-in box of `tab`'s page, at `spot`, on
    /// `host` — or, with no spot, left the boxes. `filling` is whether the
    /// window would hang a list from it now at all.
    func caret(in tab: Tab.ID, at spot: CGRect?, host: String?, filling: Bool) {
        guard let spot else {
            wanted = nil
            if pickedInto == tab { pickedInto = nil }
            guard suggesting?.tab == tab else { return }
            lowering?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, suggesting?.tab == tab else { return }
                suggesting = nil
            }
            lowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        lowering?.cancel()
        guard filling, pickedInto != tab, let host, let owner = self.tab(tab) else {
            wanted = nil
            return
        }
        wanted = Look(tab: tab, spot: spot, host: host, space: owner.space)
        look()
    }

    /// Ask the keychain for where the caret is. A read already out is not
    /// joined by another, which would only stack a second permission prompt
    /// behind the first: when it answers, the caret's place by then is read.
    private func look() {
        guard !reading, let asked = wanted else { return }
        reading = true
        let lookup = self.lookup
        Self.keychain.async { [weak self] in
            let known = Array(lookup(asked.host, asked.space).prefix(5))
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.looked(known, for: asked) }
            }
        }
    }

    private func looked(_ known: [Login], for asked: Look) {
        reading = false
        // The caret left the boxes, or filling went off, while it answered.
        guard let now = wanted else { return }
        // It moved to another site or page meanwhile: that one is still to read.
        guard now.tab == asked.tab, now.host == asked.host, now.space == asked.space else {
            look()
            return
        }
        suggesting = known.isEmpty ? nil : Suggesting(tab: now.tab, spot: now.spot, logins: known)
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Login) {
        lowering?.cancel()
        guard let tab = tab(suggesting?.tab) ?? tab(nil) else { return }
        suggesting = nil
        pickedInto = tab.id
        tab.fill(user: login.user, password: login.password, for: login.host) { [weak self] worked in
            if !worked { self?.say("Couldn't find the sign-in fields anymore") }
        }
        Vault.touch(login)
    }

    /// The list goes, and so does any read still out for it: one that answers
    /// after filling was turned off must not bring it back.
    func dropChoice() {
        wanted = nil
        suggesting = nil
    }

    /// Navigation invalidates only the page whose form moved; a background
    /// tab must not take down the account list on the active page.
    func dropChoice(in tab: Tab.ID) {
        if wanted?.tab == tab { wanted = nil }
        if suggesting?.tab == tab { suggesting = nil }
        if pickedInto == tab { pickedInto = nil }
    }

    // MARK: - the list in the panel

    /// The panel is up: what the keychain holds, read now.
    func show() {
        showing = true
        relist()
    }

    /// The panel is down: nothing of the keychain is kept in memory, and the
    /// search starts empty next time.
    func hide() {
        showing = false
        saved = []
        hunting = ""
    }

    /// Read again, if the panel is showing the list; otherwise there is
    /// nothing to bring up to date.
    func relist() {
        guard showing else { return }
        saved = read()
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: (groups[host] ?? []).sorted { $0.user < $1.user })
        }
    }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password, space: Spaces.current) else {
            say("The keychain refused it")
            return
        }
        relist()
        say("Kept for \(host)")
    }

    func forget(_ login: Login) {
        Vault.forget(host: login.host, user: login.user, space: login.space)
        relist()
    }

    func copy(_ login: Login) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(login.password, forType: .string)
        say("Password copied")
    }

}
