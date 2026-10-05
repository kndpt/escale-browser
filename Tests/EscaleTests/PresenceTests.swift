// Which mark a Space wears when several things are going on in it. What a tab
// reports (capture, audio, video) is checked against real WebKit by the
// space_media scenario; this is only the choice between them.

import Testing
@testable import Escale

struct PresenceTests {
    @Test func whatListensBeatsWhatShowsBeatsWhatSounds() {
        #expect([Presence.sound, .microphone, .video, .camera].max() == .microphone)
        #expect([Presence.sound, .video, .camera].max() == .camera)
        #expect([Presence.sound, .video].max() == .video)
        #expect([Presence.sound].max() == .sound)
    }

    @Test func everyMarkHasItsOwnSymbolAndWords() {
        let all: [Presence] = [.sound, .video, .camera, .microphone]
        #expect(Set(all.map(\.symbol)).count == all.count)
        #expect(Set(all.map(\.spoken)).count == all.count)
    }
}
