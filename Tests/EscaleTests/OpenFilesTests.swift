import Foundation
import Testing
@testable import Escale

// The open-file limit (OpenFiles.swift): raised from macOS's 256 at launch,
// and told apart when it has run out. Each runs in a process of its own, so
// the limits it sets never reach the tests running beside it.

@Suite struct OpenFilesTests {
    @Test func raisesTheDefaultToTheCeiling() async {
        await #expect(processExitsWith: .success) {
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            limit.rlim_cur = 256
            setrlimit(RLIMIT_NOFILE, &limit)
            OpenFiles.raise()
            getrlimit(RLIMIT_NOFILE, &limit)
            exit(limit.rlim_cur == OpenFiles.ceiling && OpenFiles.ceiling > 256 ? 0 : 1)
        }
    }

    @Test func tellsWhenNothingMoreOpens() async {
        await #expect(processExitsWith: .success) {
            guard !OpenFiles.exhausted else { exit(1) }
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            limit.rlim_cur = 0
            setrlimit(RLIMIT_NOFILE, &limit)
            exit(OpenFiles.exhausted ? 0 : 2)
        }
    }
}
