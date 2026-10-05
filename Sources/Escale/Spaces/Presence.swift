// What a Space has going on that you hear or that hears you, as the one small
// mark on its door in the rail. Sound, a film, the camera and the microphone can
// all be on at once and a door has room for a single mark, so the strongest wins:
// what is listening to you before what is showing you, and a picture before a
// sound. Nothing is stored or polled. A tab tells when its audio or its capture
// state changes (Tab.swift), and the rail reads the tabs as it draws, so a Space
// with nothing on costs one filter over the open tabs and no timer.
import SwiftUI
import WebKit

/// Ordered by weight: `max()` of a Space's tabs is the mark it wears.
enum Presence: Int, Comparable {
    case sound, video, camera, microphone

    static func < (a: Presence, b: Presence) -> Bool { a.rawValue < b.rawValue }

    var symbol: String {
        switch self {
        case .sound: "speaker.wave.2.fill"
        case .video: "play.rectangle.fill"
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        }
    }

    /// Spoken by VoiceOver after the Space's name.
    var spoken: String {
        switch self {
        case .sound: "playing sound"
        case .video: "playing a video"
        case .camera: "camera in use"
        case .microphone: "microphone in use"
        }
    }
}

extension Tab {
    /// A muted microphone or camera is not being heard or seen, so only an
    /// active one counts; a video is a mark only while it is audible.
    var presence: Presence? {
        if let web = built {
            if web.microphoneCaptureState == .active { return .microphone }
            if web.cameraCaptureState == .active { return .camera }
        }
        guard noisy else { return nil }
        return media.state?.video == true ? .video : .sound
    }

    /// The capture states move without a page event, so they are watched.
    func watchPresence(_ web: WKWebView) -> [NSKeyValueObservation] {
        [
            web.observe(\.microphoneCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onPresence?() }
            },
            web.observe(\.cameraCaptureState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.onPresence?() }
            },
        ]
    }
}

/// Tells the rail to draw again; the Spaces' marks are read from the tabs.
@MainActor
final class Presences: ObservableObject {
    func changed() { objectWillChange.send() }
}

extension Browser {
    func presence(in space: UUID) -> Presence? {
        (tabs + parkedTabs).lazy.filter { $0.space == space }.compactMap(\.presence).max()
    }
}

/// The mark, at the door's lower right.
struct SpaceMark: View {
    let presence: Presence

    var body: some View {
        DoorMark { Image(systemName: presence.symbol) }
    }
}
