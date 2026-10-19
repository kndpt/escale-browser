// What Screens can't fake goes to a real device: touch, hover and the
// Safari on the phone itself. The Simulator takes the address as it is, since
// it shares this Mac's localhost; it is offered only while it runs, as the
// Mac says when apps come and go (Screens.swift), and nothing is started.
//
// A phone takes it from a QR code drawn here (Core Image, nothing sent).
// localhost means the phone itself over there, so a local address becomes
// this Mac's on the network, by number: dev servers such as Vite refuse a
// `.local` name they weren't told about, and accept an address. A dev server
// listening on localhost alone can't be reached at it, so one TCP connection
// to this Mac's own address, sending nothing, says so before the phone shows
// an error (README, Privacy).
import CoreImage.CIFilterBuiltins
import Network
import SwiftUI

enum ScreenPhone {
    static var simulatorRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").isEmpty
    }

    /// Hands the page to the booted Simulator and brings it forward.
    static func simulate(_ url: URL, done: @escaping (Bool) -> Void) {
        let run = Process()
        run.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        run.arguments = ["simctl", "openurl", "booted", url.absoluteString]
        run.standardOutput = FileHandle.nullDevice
        run.standardError = FileHandle.nullDevice
        run.terminationHandler = { process in
            let opened = process.terminationStatus == 0
            DispatchQueue.main.async {
                if opened {
                    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first?.activate()
                }
                done(opened)
            }
        }
        do { try run.run() } catch { done(false) }
    }

    static func local(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// The address a phone on the same network can open: a local one moved
    /// to this Mac's address, any other as it is. None while this Mac has
    /// no network address.
    static func reachable(_ url: URL) -> URL? {
        guard local(url) else { return url }
        guard let address = lanAddress(), var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = address
        return parts.url
    }

    /// This Mac's first private IPv4 address on a network interface.
    static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var found: String?
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text.hasPrefix("10.") || text.hasPrefix("192.168.") || isPrivate172(text) {
                // Wi-Fi or Ethernet before a VPN's or a bridge's.
                if String(cString: entry.ifa_name).hasPrefix("en") { return text }
                found = found ?? text
            }
        }
        return found
    }

    private static func isPrivate172(_ text: String) -> Bool {
        let parts = text.split(separator: ".")
        guard parts.count == 4, parts[0] == "172", let second = Int(parts[1]) else { return false }
        return (16...31).contains(second)
    }

    /// Whether the server answers at this Mac's network address: one
    /// connection, nothing sent, given a second.
    static func answers(_ url: URL, done: @escaping (Bool) -> Void) {
        guard let host = url.host(), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? (url.scheme == "https" ? 443 : 80))) else {
            done(false); return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        var told = false
        let tell: (Bool) -> Void = { answer in
            DispatchQueue.main.async {
                guard !told else { return }
                told = true
                connection.cancel()
                done(answer)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: tell(true)
            case .failed, .waiting: tell(false)
            default: break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tell(false) }
    }

    static func code(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let image = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let drawn = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: drawn, size: NSSize(width: image.extent.width, height: image.extent.height))
    }
}

/// The popover behind "On iPhone": the code, the address it holds, and why
/// the phone won't get there when it won't.
struct PhoneCode: View {
    let page: URL
    @SwiftUI.Environment(\.chromeMetrics) private var metrics
    @State private var listening: Bool?

    var body: some View {
        let target = ScreenPhone.reachable(page)
        VStack(alignment: .leading, spacing: metrics.length(10)) {
            if let target, let image = ScreenPhone.code(target.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: metrics.length(168), height: metrics.length(168))
                    .padding(metrics.length(8))
                    // A code reads dark on light, whatever the theme.
                    .background(Color.white, in: RoundedRectangle(cornerRadius: metrics.length(8), style: .continuous))
                    .accessibilityLabel("QR code for \(target.absoluteString)")
                HStack(spacing: metrics.length(4)) {
                    Text(target.absoluteString)
                        .font(.system(size: metrics.length(Metrics.callsMono), design: .monospaced))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    CopyButton(help: "Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(target.absoluteString, forType: .string)
                    }
                }
                if listening == false {
                    Text("The server only listens on this Mac. Start it with --host (Vite) or -H 0.0.0.0 (Next).")
                        .font(.system(size: metrics.length(Metrics.infoText)))
                        .foregroundStyle(Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                } else if ScreenPhone.local(page) {
                    Text("Your phone needs to be on the same network.")
                        .font(.system(size: metrics.length(Metrics.infoText)))
                        .foregroundStyle(Palette.muted)
                }
            } else {
                Text("This Mac has no network address for a phone to reach.")
                    .font(.system(size: metrics.length(Metrics.infoText)))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(metrics.length(Metrics.infoInset))
        .frame(width: metrics.length(Metrics.screenCodeWidth), alignment: .leading)
        .popoverGround()
        .onAppear {
            guard ScreenPhone.local(page), let target else { return }
            ScreenPhone.answers(target) { listening = $0 }
        }
    }
}
