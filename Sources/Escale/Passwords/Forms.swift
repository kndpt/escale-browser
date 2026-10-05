import WebKit

// What the page says about itself that a browser has to know: where the
// keyboard is, whether it is about to take the screen, and whether there is a
// sign-in on it — and when one has just been sent, so the password can be
// offered a place in the keychain.
//
// Filling goes through the field's own setter and fires the events a keystroke
// would. Assigning to .value behind a framework's back leaves it thinking the
// box is still empty, which is a sign-in button that stays grey.

final class FormRelay: NSObject, WKScriptMessageHandler {
    static let name = "escaleForms"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let kind = body["kind"] as? String
        else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            // Where the keyboard is and whether the page holds the screen
            // belong to whatever document is showing. Only what touches
            // credentials waits for the committed page: a fullscreen exit
            // dropped there would leave the window black.
            let credentials = tab.acceptsFormMessage(message)
            switch kind {
            case "submit":
                guard credentials else { return }
                tab.sentSignIn(
                    user: body["user"] as? String ?? "",
                    password: body["password"] as? String ?? ""
                )
            case "settled":
                guard credentials else { return }
                tab.settleSignIn(navigated: false)
            case "focus":
                // Said on every click and change of focus; set only when it
                // changes, as each change redraws whatever watches the tab.
                let typing = body["typing"] as? Bool ?? false
                if tab.typing != typing { tab.typing = typing }
                guard credentials else { return }
                // Which sign-in box the caret is in, and where it sits on the
                // page — so a list of accounts can hang from it.
                if let rect = body["rect"] as? [String: Double],
                   let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                    tab.fieldFocused(CGRect(x: x, y: y, width: w, height: h))
                } else {
                    tab.fieldFocused(nil)
                }
            case "fullscreen":
                tab.immersed = body["on"] as? Bool ?? false
            default:
                break
            }
        }
    }

    /// Whether sites are offered passkeys here (Settings › Passwords).
    ///
    /// A build without Apple's browser entitlement can't do them: WebKit then
    /// answers isUserVerifyingPlatformAuthenticatorAvailable() with false,
    /// yet the API object exists, so sites offer the passkey path and strand
    /// you there. Taken away, they go straight to the password. Signed with
    /// the entitlement, as releases are, this is on, and Escale carries out
    /// the sites' requests itself (see Passkeys.swift).
    static var passkeysOffered: Bool {
        get { Store.settings.bool(forKey: "passkeys") }
        set { Store.settings.set(newValue, forKey: "passkeys") }
    }

    /// Only the passkey object goes. navigator.credentials itself stays: sites
    /// use it for stored passwords too, and that half still works.
    ///
    /// Unless an extension answers passkey requests itself — a password
    /// manager with your passkeys in it, as 1Password is. It puts its own get
    /// and create on navigator.credentials, and reaches for the passkey object
    /// from its own script as it does; from then on sites see the object, and
    /// the extension is the one they ask. Whatever it leaves to the browser is
    /// refused at once, as if you had said no, where WebKit would try and fail.
    static let withoutPasskeys = Bundled.script("without-passkeys.js")

    /// What the page's sign-in half may do, from Settings › Passwords: say
    /// that a password was sent, for the offer to keep it, and where the
    /// sign-in box the caret is in sits, for the accounts to hang from. Set
    /// before a page is armed (see Browser.follow). With neither, nothing in
    /// the page looks for sign-in boxes; drafts, typing and full screen
    /// don't depend on them.
    @MainActor static var saving = true
    @MainActor static var filling = true

    /// The same, for a page already up.
    @MainActor static var signIns: String {
        "window.__escaleForms && window.__escaleForms.signIns(\(saving), \(filling))"
    }

    /// The body is read once. Re-arming a page only JSON-encodes the two
    /// switches, preserving document-end/main-frame injection in Tab.arm.
    private static let page = Bundled.script("forms.js")

    @MainActor static var script: String {
        Bundled.configured(page, with: ["saving": saving, "filling": filling])
    }
}
