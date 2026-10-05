import SwiftUI

/// The accounts kept for a site, hanging from the sign-in box the caret is
/// in. The same white and hairline as everything else that floats over a
/// page; one line per account, the name in ink and the site under it in
/// grey; a click puts both into the form. It follows the box when the page
/// scrolls, and goes when the caret does.
struct AccountList: View {
    /// For the click; what is listed is `asked`.
    let logins: Logins
    let asked: Logins.Suggesting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(asked.logins) { login in
                Row(login: login) { logins.choose(login) }
            }
            HStack(spacing: 6) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .regular))
                Text("From your keychain")
                    .font(.system(size: 10.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.faint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Palette.wash.opacity(0.5))
        }
        .frame(width: max(240, min(360, asked.spot.width)), alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .glass(.panel, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        // Just under the box, left edges lined up. The offset is from the
        // stage's top-left, which is also the web view's.
        .offset(x: asked.spot.minX, y: asked.spot.maxY + 6)
    }

    private struct Row: View {
        let login: Login
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Text(String(login.user.first.map { String($0).uppercased() } ?? "•"))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Palette.ink)
                        .frame(width: 22, height: 22)
                        .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(login.user.isEmpty ? "No name" : login.user)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                        Text(login.host)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

/// The list over `tab`'s page, while the caret is in one of its sign-in
/// boxes: it watches the passwords' owner, not the window (see Logins.swift).
struct AccountsOver: View {
    @ObservedObject var logins: Logins
    let tab: Tab.ID

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let asked = logins.suggesting, asked.tab == tab {
                AccountList(logins: logins, asked: asked)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(Motion.quick, value: logins.suggesting)
    }
}

/// Offered once, answered once, rising from the bottom with the window's
/// other lines. The password is never shown back to you — there is nothing
/// to be learned from reading your own password.
struct KeepAsking: View {
    @ObservedObject var logins: Logins

    var body: some View {
        ZStack {
            if let offer = logins.offering {
                asking(offer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.settle, value: logins.offering)
    }

    private func asking(_ offer: Logins.Offer) -> some View {
        let login = offer.login
        return HStack(spacing: 12) {
            Text(offer.changed
                 ? "Update the password for \(login.user) on \(login.host)?"
                 : (login.user.isEmpty
                    ? "Save this password for \(login.host)?"
                    : "Save the password for \(login.user) on \(login.host)?"))
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            Button(offer.changed ? "Update" : "Save") { logins.keepOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.inverse)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Palette.ink, in: Capsule())
            Button("Not now") { logins.dropOffer() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
            if !offer.changed {
                Button("Never here") { logins.neverOffer() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .glass(.chip, in: Capsule())
    }
}
