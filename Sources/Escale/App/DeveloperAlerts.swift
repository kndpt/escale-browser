import Darwin
import SwiftUI
import UserNotifications

// Local development events, handed to macOS notifications on request. GitHub
// webhooks cannot reach a laptop without a server and polling would wake the
// browser and make network requests; tools already running on this Mac can
// instead send one bounded JSON line to a user-only Unix socket. The socket
// exists only while enabled. A dispatch source sleeps until a sender connects;
// there is no timer, scan or GitHub credential in the browser.

@MainActor
final class DeveloperAlerts: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = DeveloperAlerts()

    enum Kind: String, Codable, CaseIterable {
        case agent, build, pullRequest = "pr", workflow
    }

    struct Event: Codable {
        let kind: Kind
        let title: String
        let body: String

        var cleaned: Event? {
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 100, body.count <= 500 else { return nil }
            return Event(kind: kind, title: title, body: body)
        }
    }

    @Published private(set) var received = 0
    @Published private(set) var filtered = 0
    @Published private(set) var posted = 0
    @Published private(set) var trouble: String?

    private weak var prefs: Preferences?
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private weak var previousDelegate: UNUserNotificationCenterDelegate?
    private(set) var running = false
    var delegateActive: Bool { UNUserNotificationCenter.current().delegate === self }

    static var socket: URL { Store.file("alerts.sock") }

    func start(for prefs: Preferences) {
        guard !running else { return }
        self.prefs = prefs
        let path = Self.socket.path
        do { try FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true) }
        catch { trouble = "Could not open the notification socket"; return }
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { trouble = "Could not open the notification socket"; return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); trouble = "Notification socket path is too long"; return }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            trouble = "Could not open the notification socket"
            return
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
        trouble = nil
        let center = UNUserNotificationCenter.current()
        previousDelegate = center.delegate
        center.delegate = self
        Task { await requestPermission() }
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(Self.socket.path)
        Array(clients.values).forEach { $0.drop() }
        clients = [:]
        prefs = nil
        running = false
        let center = UNUserNotificationCenter.current()
        if center.delegate === self { center.delegate = previousDelegate }
        previousDelegate = nil
    }

    private func requestPermission() async {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            if running, !granted { trouble = "Allow Escale notifications in macOS Settings to see these alerts" }
        } catch {
            if running { trouble = "macOS could not allow notifications for Escale" }
        }
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid = uid_t(0), gid = gid_t(0)
        guard clients.count < 8, getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); return }
        clients[fd] = Client(fd: fd, receive: { [weak self] data in self?.receive(data) ?? ["accepted": false] },
                             gone: { [weak self] in self?.clients[$0] = nil })
    }

    private func receive(_ data: Data) -> [String: Any] {
        guard let event = try? JSONDecoder().decode(Event.self, from: data),
              let clean = event.cleaned else { return ["accepted": false, "reason": "invalid event"] }
        received += 1
        guard let prefs, prefs.developerAlerts else {
            filtered += 1
            return ["accepted": false, "reason": "disabled"]
        }
        let allowed: Bool
        switch clean.kind {
        case .agent: allowed = prefs.alertAgents
        case .build: allowed = prefs.alertBuilds
        case .pullRequest: allowed = prefs.alertPRs
        case .workflow: allowed = prefs.alertWorkflows
        }
        guard allowed else {
            filtered += 1
            return ["accepted": false, "reason": "disabled"]
        }
        Task {
            guard running, prefs.developerAlerts else { return }
            let content = UNMutableNotificationContent()
            content.title = clean.title
            content.body = clean.body
            content.subtitle = clean.kind == .agent ? "Agent" : clean.kind == .build ? "Build"
                : clean.kind == .pullRequest ? "Pull request" : "Workflow"
            do {
                try await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "escale.local.\(UUID().uuidString)", content: content, trigger: nil))
                posted += 1
            } catch {
                trouble = "macOS could not post a developer notification"
            }
        }
        return ["accepted": true]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                             willPresent notification: UNNotification,
                                             withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix("escale.local.") ? [.banner] : [])
    }

    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let timeout: DispatchSourceTimer
        private let receive: (Data) -> [String: Any]
        private let gone: (Int32) -> Void
        private var closed = false

        init(fd: Int32, receive: @escaping (Data) -> [String: Any], gone: @escaping (Int32) -> Void) {
            self.fd = fd
            self.receive = receive
            self.gone = gone
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            timeout = DispatchSource.makeTimerSource(queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            timeout.setEventHandler { [weak self] in self?.drop() }
            timeout.schedule(deadline: .now() + 5)
            timeout.resume()
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 1024)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            guard bytes.count <= 2048 else { say(["accepted": false, "reason": "event too long"]); return }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            say(receive(Data(bytes[..<newline])))
        }

        private func say(_ reply: [String: Any]) {
            if var data = try? JSONSerialization.data(withJSONObject: reply) {
                data.append(0x0A)
                data.withUnsafeBytes { raw in _ = Darwin.write(fd, raw.baseAddress, raw.count) }
            }
            drop()
        }

        func drop() {
            guard !closed else { return }
            closed = true
            if !source.isCancelled { source.cancel() }
            timeout.cancel()
            close(fd)
            gone(fd)
        }
    }
}
