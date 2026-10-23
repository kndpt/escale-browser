import Foundation

// How many files the browser may hold open at once.
//
// macOS lets an app hold 256. WebKit keeps each extension's databases open in
// this process and doesn't always close them: Dashlane's rules database was
// opened again about once a minute, until nothing could be opened at all —
// not its storage, not its worker, not a socket. The limit is raised at
// launch to the most a process may ask for, as other browsers do, which
// gives such a leak forty times the room.
//
// When the files run out anyway, an extension taken up afresh can't open its
// storage either, and starting it over only loses its session: a password
// manager signed out every minute (Extensions.revive asks here first).

enum OpenFiles {
    /// The most a process may ask for without privileges.
    static var ceiling: rlim_t {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 0 }
        return min(rlim_t(OPEN_MAX), limit.rlim_max)
    }

    /// The soft limit raised to the ceiling; never lowered.
    static func raise() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0, limit.rlim_cur < ceiling else { return }
        limit.rlim_cur = ceiling
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            NSLog("OpenFiles: couldn't raise the limit (%d)", errno)
        }
    }

    /// Whether the process can't open another file.
    static var exhausted: Bool {
        let file = open("/dev/null", O_RDONLY)
        guard file < 0 else {
            close(file)
            return false
        }
        return errno == EMFILE || errno == ENFILE
    }
}
