import Darwin
import Foundation

// Which local ports have a server listening right now, so the Localhost list
// can tell a visit from a server that is still there. The kernel's socket
// table is read in process through libproc: no connection, no request, no
// port scan, nothing sent to a development server. One read costs about 6 ms
// for 530 processes on a development Mac (run from a script, not the app),
// and it happens only when the Localhost panel opens.
// A process of another user is invisible without privileges, so a server
// started with sudo reads as "not listening"; the entry stays clickable.

struct Listening: Equatable {
    /// Ports reachable at 127.0.0.1 and at ::1: bound to that loopback address
    /// or to every address of the family. A dual-stack wildcard (Node's
    /// `listen(5173)`) answers on both.
    var v4: Set<UInt16> = []
    var v6: Set<UInt16> = []
    var taken = Date()

    /// Whether a server answers at this endpoint. `localhost` and its
    /// subdomains resolve to both loopbacks, so either family will do.
    func serves(origin: String) -> Bool {
        guard let parts = URLComponents(string: origin), let scheme = parts.scheme,
              let host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        let port = UInt16(exactly: parts.port ?? (scheme == "https" ? 443 : 80))
        guard let port else { return false }
        if host == "::1" { return v6.contains(port) }
        if host.split(separator: ".").first == "127" { return v4.contains(port) }
        return v4.contains(port) || v6.contains(port)
    }

    /// Keeps a listening socket's address as the families it is reachable on.
    mutating func add(port: UInt16, v4Bound: UInt32?, v6Bound: [UInt8]?, dual: Bool) {
        if let v4Bound, v4Bound == 0 || v4Bound & 0xFF == 127 { v4.insert(port) }
        guard let v6Bound else { return }
        let any = v6Bound.allSatisfy { $0 == 0 }
        let loopback = v6Bound.dropLast().allSatisfy { $0 == 0 } && v6Bound.last == 1
        if any || loopback { v6.insert(port) }
        if any && dual { v4.insert(port) }
    }

    /// When this Mac last started: a server does not survive that unless it
    /// is relaunched, so a visit older than this has no live server behind it.
    static let booted: Date? = {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }()

    /// A snapshot of the user's listening TCP sockets, or nil when the table
    /// cannot be read, which says nothing about any server. Blocking: call it
    /// off the main thread.
    static func read() -> Listening? {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size + 32)
        let filled = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return nil }
        var snapshot = Listening()
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.size) where pid > 0 {
            let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard size > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
            let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * MemoryLayout<proc_fdinfo>.size))
            guard listed > 0 else { continue }
            for fd in fds.prefix(Int(listed) / MemoryLayout<proc_fdinfo>.size)
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                let length = Int32(MemoryLayout<socket_fdinfo>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP),
                      info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
                let socket = info.psi.soi_proto.pri_tcp.tcpsi_ini
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_lport))
                let flags = Int32(socket.insi_vflag)
                var six = socket.insi_laddr.ina_6
                let bytes6 = withUnsafeBytes(of: &six) { Array($0) }
                snapshot.add(port: port,
                             v4Bound: flags & INI_IPV4 != 0 ? socket.insi_laddr.ina_46.i46a_addr4.s_addr : nil,
                             v6Bound: flags & INI_IPV6 != 0 ? bytes6 : nil,
                             dual: flags & INI_IPV4 != 0)
            }
        }
        snapshot.taken = Date()
        return snapshot
    }
}
