import Combine
import Foundation
import Testing
@testable import Escale

// Origins, ports and spaces are the hub's identity. A visit's last page is
// kept, but no guessed or external host enters the list.
@MainActor
@Suite struct LocalhostTests {
    @Test(arguments: [
        ("http://localhost:3000/a", "http://localhost:3000"),
        ("https://app.localhost:5173/", "https://app.localhost:5173"),
        ("http://127.0.0.1:8080/", "http://127.0.0.1:8080"),
        ("http://[::1]:8080/", "http://[::1]:8080"),
        ("http://localhost:80/", "http://localhost"),
        ("https://localhost:443/", "https://localhost"),
        ("https://localhost:80/", "https://localhost:80"),
    ])
    func recognises(url: String, origin: String) throws {
        #expect(Localhost.origin(of: try #require(URL(string: url))) == origin)
    }

    @Test(arguments: ["https://example.com/", "http://127.evil/", "file:///tmp/page", "http://192.168.1.4/"])
    func ignores(url: String) throws {
        #expect(Localhost.origin(of: try #require(URL(string: url))) == nil)
    }

    @Test func keepsPortsAndSpacesApart() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("localhost.json")
        let a = UUID(), b = UUID()
        let hub = Localhost(file: file)
        hub.record(try #require(URL(string: "http://localhost:3000/a")), title: "App", in: a)
        hub.record(try #require(URL(string: "http://localhost:5173/")), title: "Vite", in: a)
        hub.record(try #require(URL(string: "http://localhost:3000/b")), title: "Other space", in: b)
        #expect(hub.entries(in: a).map(\.origin) == ["http://localhost:5173", "http://localhost:3000"])
        #expect(hub.entries(in: b).map(\.title) == ["Other space"])
        Writer.to(file).flush()
        let restored = Localhost(file: file)
        #expect(restored.entries(in: a).map(\.title) == ["Vite", "App"])
        restored.forget(space: a)
        #expect(restored.entries(in: a).isEmpty)
        #expect(restored.entries(in: b).count == 1)
        restored.forget(space: b)
        Writer.to(file).flush()
        #expect(Localhost(file: file).entries(in: b).isEmpty)
    }

    @Test func historyRemovalsPruneOnlyTheirSpace() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("localhost.json")
        let a = UUID(), b = UUID()
        let old = Localhost.Entry(origin: "http://localhost:3000", url: "http://localhost:3000/old",
                                  title: "Old", visited: Date(timeIntervalSince1970: 1_000))
        let middle = Localhost.Entry(origin: "http://localhost:5173", url: "http://localhost:5173/middle",
                                     title: "Middle", visited: Date(timeIntervalSince1970: 2_000))
        let recent = Localhost.Entry(origin: "http://localhost:8080", url: "http://localhost:8080/recent",
                                     title: "Recent", visited: Date(timeIntervalSince1970: 3_000))
        try JSONEncoder().encode([a.uuidString: [old, middle], b.uuidString: [recent]]).write(to: file)
        let hub = Localhost(file: file)
        hub.forget(url: try #require(URL(string: old.url)), in: b)
        #expect(hub.entries(in: a) == [old, middle])
        hub.forget(url: try #require(URL(string: old.url)), in: a)
        #expect(hub.entries(in: a) == [middle])
        hub.forget(from: Date(timeIntervalSince1970: 1_500), in: a)
        #expect(hub.entries(in: a).isEmpty)
        #expect(hub.entries(in: b) == [recent])
        hub.forget(from: Date(timeIntervalSince1970: 2_500), through: Date(timeIntervalSince1970: 3_500), in: b)
        Writer.to(file).flush()
        #expect(Localhost(file: file).entries(in: b).isEmpty)
    }

    @Test func takesATitleOnlyWhileThePageNamesItself() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("localhost.json")
        let space = UUID()
        let url = try #require(URL(string: "http://localhost:3000/"))
        let hub = Localhost(file: file)
        hub.record(url, title: "", in: space)
        let visited = try #require(hub.entries(in: space).first?.visited)
        let long = String(repeating: "x", count: 100)
        hub.retitle(url, title: long, in: space, at: visited.addingTimeInterval(1))
        #expect(hub.entries(in: space).first?.title == String(long.prefix(80)))
        var changes = 0
        let watch = hub.objectWillChange.sink { changes += 1 }
        defer { watch.cancel() }
        // The same long title again, then a counter after the page arrived.
        hub.retitle(url, title: long, in: space, at: visited.addingTimeInterval(2))
        hub.retitle(url, title: "(3) App", in: space, at: visited.addingTimeInterval(History.naming))
        #expect(changes == 0)
        #expect(hub.entries(in: space).first?.title == String(long.prefix(80)))
    }

    @Test func reopensOnlyOrdinaryTabs() throws {
        let url = try #require(URL(string: "http://localhost:3000/a"))
        #expect(!Localhost.reuses(shy: true, address: url, origin: "http://localhost:3000"))
        #expect(Localhost.reuses(shy: false, address: url, origin: "http://localhost:3000"))
        #expect(!Localhost.reuses(shy: false, address: url, origin: "http://localhost:5173"))
    }

    private func entry(_ url: String) throws -> Localhost.Entry {
        let address = try #require(URL(string: url))
        return Localhost.Entry(origin: try #require(Localhost.origin(of: address)), url: url, title: "", visited: Date())
    }

    @Test func bookmarkOwnsItsLocalEnvironmentWhateverItShows() throws {
        let app = Bookmark(title: "App", url: "https://staging.example.com/", children: nil, environments: [
            BookmarkEnvironment(name: "dev", url: "http://localhost:5173/"),
            BookmarkEnvironment(name: "staging", url: "https://staging.example.com/"),
            BookmarkEnvironment(name: "prod", url: "https://example.com/"),
        ])
        let folder = Bookmark.folder("Work", [app])
        let found = Localhost.destinations(for: try entry("http://localhost:5173/login"), in: [folder])
        #expect(found.map(\.bookmark) == [app.id])
        #expect(found.first?.environment?.name == "DEV")
        #expect(found.first?.url.absoluteString == "http://localhost:5173/")
        #expect(Localhost.destinations(for: try entry("http://localhost:3000/"), in: [folder]).isEmpty)
    }

    @Test func bookmarkWithoutEnvironmentsUsesItsOwnAddress() throws {
        let plain = Bookmark.site("Vite", try #require(URL(string: "http://localhost:5173/app")))
        let other = Bookmark.site("Docs", try #require(URL(string: "https://example.com/")))
        let found = Localhost.destinations(for: try entry("http://localhost:5173/"), in: [other, plain])
        #expect(found == [Localhost.Destination(bookmark: plain.id, environment: nil, url: try #require(URL(string: plain.url ?? "")))])
    }

    @Test func pathTellsTwoDestinationsOnOnePortApart() throws {
        let console = Bookmark(title: "Console", url: "http://localhost:8080/dev/", children: nil, environments: [
            BookmarkEnvironment(name: "dev", url: "http://localhost:8080/dev/", depth: 1),
            BookmarkEnvironment(name: "prod", url: "http://localhost:8080/prod/", depth: 1),
        ])
        #expect(Localhost.destinations(for: try entry("http://localhost:8080/prod/users"), in: [console])
            .first?.environment?.name == "PROD")
        // A page on neither path chooses neither: no guess.
        #expect(Localhost.destinations(for: try entry("http://localhost:8080/"), in: [console]).isEmpty)
    }

    @Test func severalBookmarksAreAllOffered() throws {
        let a = Bookmark.site("A", try #require(URL(string: "http://localhost:5173/")))
        let b = Bookmark.site("B", try #require(URL(string: "http://localhost:5173/admin")))
        #expect(Localhost.destinations(for: try entry("http://localhost:5173/"), in: [a, b]).map(\.bookmark) == [a.id, b.id])
    }

    // MARK: Lifecycle of an entry after its server goes

    private func visit(_ origin: String, at time: TimeInterval) -> Localhost.Entry {
        Localhost.Entry(origin: origin, url: origin + "/", title: "", visited: Date(timeIntervalSince1970: time))
    }

    @Test func aReadingAfterTheVisitDecides() {
        let entry = visit("http://localhost:5173", at: 1_000)
        let up = Listening(v4: [5173], v6: [], taken: Date(timeIntervalSince1970: 2_000))
        let down = Listening(v4: [3000], v6: [], taken: Date(timeIntervalSince1970: 2_000))
        #expect(Localhost.availability(of: entry, listening: up, booted: nil) == .running)
        #expect(Localhost.availability(of: entry, listening: down, booted: nil) == .stopped)
        // The server is back on the same origin: running again, no new visit needed.
        let again = Listening(v4: [5173], v6: [], taken: Date(timeIntervalSince1970: 3_000))
        #expect(Localhost.availability(of: entry, listening: again, booted: nil) == .running)
    }

    @Test func aVisitNewerThanTheReadingIsNotContradictedByIt() {
        let entry = visit("http://localhost:5173", at: 3_000)
        let old = Listening(v4: [], v6: [], taken: Date(timeIntervalSince1970: 2_000))
        #expect(Localhost.availability(of: entry, listening: old, booted: nil) == .unconfirmed)
    }

    @Test func aRestartOutdatesEarlierVisitsUntilTheyAreRead() {
        let booted = Date(timeIntervalSince1970: 2_000)
        let before = visit("http://localhost:5173", at: 1_000)
        let after = visit("http://127.0.0.1:51000", at: 3_000)
        #expect(Localhost.availability(of: before, listening: nil, booted: booted) == .restarted)
        #expect(Localhost.availability(of: after, listening: nil, booted: booted) == .unconfirmed)
        // A server that starts by itself at login is found by the reading.
        let up = Listening(v4: [5173], v6: [], taken: Date(timeIntervalSince1970: 4_000))
        #expect(Localhost.availability(of: before, listening: up, booted: booted) == .running)
        // A reading that failed is no reading: the entry is not called stopped.
        #expect(Localhost.availability(of: after, listening: nil, booted: nil) == .unconfirmed)
        #expect(Localhost.availability(of: before, listening: nil, booted: nil) == .unconfirmed)
    }

    @Test func theDoorCountsWhatMayStillLoad() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let space = UUID()
        let hub = Localhost(file: folder.appendingPathComponent("localhost.json"))
        hub.record(try #require(URL(string: "http://localhost:5173/")), title: "Vite", in: space)
        hub.record(try #require(URL(string: "http://127.0.0.1:51000/")), title: "Auth", in: space)
        // Visited just now, never read: both may load, as before.
        #expect(hub.reachable(in: space) == 2)
        #expect(hub.entries(in: space).count == 2)
    }

    @Test func staleEntriesStayInTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("localhost.json")
        let space = UUID()
        let old = visit("http://localhost:5173", at: 1_000)
        try JSONEncoder().encode([space.uuidString: [old]]).write(to: file)
        let hub = Localhost(file: file)
        // Long before this Mac started: not counted, but not deleted either.
        #expect(hub.availability(of: old) == .restarted)
        #expect(hub.reachable(in: space) == 0)
        #expect(hub.entries(in: space) == [old])
        // Visiting the same origin again brings it back.
        hub.record(try #require(URL(string: "http://localhost:5173/")), title: "", in: space)
        #expect(hub.reachable(in: space) == 1)
    }

    // MARK: Listening ports

    @Test(arguments: [
        ("http://localhost:5173", true), ("http://localhost:5174", false),
        ("http://app.localhost:5173", true), ("http://127.0.0.1:5173", true),
        ("http://[::1]:5173", false), ("http://[::1]:3000", true),
        ("http://localhost", true), ("https://localhost", false),
        ("https://localhost:80", true), ("http://localhost:443", false),
    ])
    func matchesByPortAndFamily(origin: String, serves: Bool) {
        // 5173 on 127.0.0.1 only, 3000 on ::1 only, 80 on both.
        let snapshot = Listening(v4: [5173, 80], v6: [3000, 80])
        #expect(snapshot.serves(origin: origin) == serves)
    }

    @Test func readsBoundAddresses() {
        var snapshot = Listening()
        let loopback4: UInt32 = 0x0100007F, lan4: UInt32 = 0x0100A8C0
        var one = [UInt8](repeating: 0, count: 16); one[15] = 1
        let any6 = [UInt8](repeating: 0, count: 16)
        var lan6 = [UInt8](repeating: 0, count: 16); lan6[0] = 0xFE; lan6[1] = 0x80; lan6[15] = 1
        snapshot.add(port: 1, v4Bound: loopback4, v6Bound: nil, dual: false)
        snapshot.add(port: 2, v4Bound: 0, v6Bound: nil, dual: false)
        snapshot.add(port: 3, v4Bound: lan4, v6Bound: nil, dual: false)
        snapshot.add(port: 4, v4Bound: nil, v6Bound: one, dual: false)
        snapshot.add(port: 5, v4Bound: 0, v6Bound: any6, dual: true)
        snapshot.add(port: 6, v4Bound: nil, v6Bound: any6, dual: false)
        snapshot.add(port: 7, v4Bound: nil, v6Bound: lan6, dual: false)
        #expect(snapshot.v4 == [1, 2, 5])
        #expect(snapshot.v6 == [4, 5, 6])
    }

    @Test func theKernelTableShowsARealListenerAndItsEnd() throws {
        func listener() throws -> (Int32, UInt16) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            try #require(fd >= 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = UInt32(0x0100007F)
            address.sin_port = 0
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            try #require(bound == 0 && listen(fd, 1) == 0)
            var named = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &named) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            return (fd, UInt16(bigEndian: named.sin_port))
        }
        let (fd, port) = try listener()
        let reading = try #require(Listening.read())
        #expect(reading.serves(origin: "http://127.0.0.1:\(port)"))
        #expect(reading.serves(origin: "http://localhost:\(port)"))
        close(fd)
        let after = try #require(Listening.read())
        #expect(!after.serves(origin: "http://127.0.0.1:\(port)"))
    }
}
