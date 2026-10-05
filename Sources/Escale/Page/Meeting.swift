import AppKit
import WebKit

// A Google Meet meeting kept in view after you have gone somewhere else: the
// people in it along the top, the screen someone shares beneath them, whole and
// at its own shape, and the meeting's commands along the bottom — microphone,
// camera, presenting, the few options there are, and hanging up.
//
// It is not a video's picture in picture. A film has one picture and a
// timeline; a meeting has people, some with no camera on, a shared screen, and
// states that are the meeting's, not the window's. So the window keeps only
// what floating shares with a film (Float.swift: the panel, its place, moving
// and sizing it) and has its own content.
//
// The page is the meeting, and it is moved, not copied: a second page would be
// a second connection. The page draws the people and the screen itself
// (Page/Scripts/meeting.js), with the streams its own tiles play, over its own
// layout. That layout is kept at the size of an ordinary window by zooming the
// page out while it floats: in a window a third of a screen wide, Meet shows
// one picture and stops receiving the others, which is how a presentation came
// to float without anyone in it.
//
// Every command presses the page's own button and shows the state the page
// shows. A button the page does not have is not offered: a control that could
// not be pressed would be a lie. There is no separate close: beside a hang-up,
// an "x" reads as leaving the meeting, and going back to the tab is the way to
// be rid of the window.
//
// The window lasts as long as the meeting. It opens once there is a meeting
// (a way to leave it, or anything arriving from the other side), not once
// someone's camera is playing, and does not close when every camera is off: a
// window that closed then put the meeting back in a tab of a Space nobody was
// looking at, and the page holding the call was no longer the one on show.
enum Meeting {
    /// The page's zoom while it floats. At 0.4, a window 360 points wide is,
    /// to the site, a window 900 pixels wide: its ordinary layout, with
    /// everyone in it.
    static let zoom: CGFloat = 0.4
    /// The window's first size, the smallest it can be, and the band at the
    /// bottom that holds the commands.
    static let size = NSSize(width: 380, height: 400)
    static let smallest = NSSize(width: 300, height: 240)
    static let band: CGFloat = 60

    /// What the page has and how it stands, read twice a second.
    struct State {
        /// Whether there is still a meeting: a way to leave, or anything
        /// arriving from the other side.
        var live = false
        /// `open` or `muted`; `on` or `off`; `on` or `off`; `up` or `down`.
        /// Nil when the page has no such button.
        var microphone: String?
        var camera: String?
        var present: String?
        var hand: String?
        var leave = false
        /// The page asks whether to leave or to end the call for everyone.
        var asking = false

        init() {}

        init(_ answer: [String: Any]) {
            live = answer["live"] as? Bool ?? false
            microphone = answer["mic"] as? String
            camera = answer["camera"] as? String
            present = answer["present"] as? String
            hand = answer["hand"] as? String
            leave = answer["leave"] as? Bool ?? false
            asking = answer["asking"] as? Bool ?? false
        }
    }

    // (see Page/Scripts/meeting.js)
    private static let page = Bundled.script("meeting.js")
    /// Draws the meeting over the page, and answers `floating` when there is
    /// one to draw, `none` when there is not.
    static let on = Bundled.configured(page, with: [
        "action": "on",
        // CSS pixels in a point, at the zoom the page floats at.
        "unit": Double(1 / zoom),
        "colours": [
            "ground": Palette.Film.css(Palette.Film.ground),
            "card": Palette.Film.css(Palette.Film.card),
            "face": Palette.Film.css(Palette.Film.face),
            "ink": Palette.Film.css(Palette.Film.ink),
            "faint": Palette.Film.css(Palette.Film.faint),
            "alert": Palette.Film.css(Palette.Film.hangUp),
            // Behind a name, so it holds on a bright picture.
            "shade": Palette.Film.css(Palette.Film.ground),
        ],
    ])
    static let state = Bundled.configured(page, with: ["action": "state"])
    static let off = Bundled.configured(page, with: ["action": "off"])
    /// `microphone`, `camera`, `present`, `hand` or `leave`. Answers whether
    /// the page had the button to press; `leave` answers a host's question
    /// with leave, never with ending the call for everyone.
    static func press(_ name: String) -> String {
        Bundled.configured(page, with: ["action": "press", "name": name])
    }

    /// The commands along the bottom, always in view, and the way back to the
    /// tab and to the mini player at the top, in view while the pointer is over
    /// the window. Everywhere else a drag moves the window (see Grip).
    final class Controls: Grip {
        var onReturn: (() -> Void)?
        var onMinimize: (() -> Void)?
        var onPress: ((String) -> Void)?

        private let back = NSButton()
        private let minimize = NSButton()
        private let microphone = NSButton()
        private let camera = NSButton()
        private let present = NSButton()
        private let options = NSButton()
        private let hang = NSButton()
        private var near = false
        private var state = State()

        override init(frame: NSRect) {
            super.init(frame: frame)
            dress(back, "arrow.up.forward", 12, round: 15, action: #selector(pressedReturn))
            name(back, "Back to the meeting tab")
            dress(minimize, "pip.exit", 12, round: 15, action: #selector(pressedMinimize))
            name(minimize, "Return to mini player")
            dress(microphone, "mic.fill", 15, round: 20, action: #selector(pressedMicrophone))
            dress(camera, "video.fill", 14, round: 20, action: #selector(pressedCamera))
            dress(present, "rectangle.on.rectangle", 14, round: 20, action: #selector(pressedPresent))
            dress(options, "ellipsis", 15, round: 20, action: #selector(pressedOptions))
            name(options, "More options")
            dress(hang, "phone.down.fill", 15, round: 20, action: #selector(pressedHangUp))
            hang.layer?.backgroundColor = Palette.Film.hangUp.cgColor
            name(hang, "Leave the meeting")
            [back, minimize].forEach { $0.alphaValue = 0 }
            // What the page offers is known a beat after the window opens.
            commands.forEach { $0.isHidden = true }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        private var commands: [NSButton] { [microphone, camera, present, options, hang] }

        override var pressable: [NSButton] { commands + (near ? [back, minimize] : []) }

        private var named: [(NSButton, String)] {
            [(back, "return"), (minimize, "mini player"), (microphone, "microphone"),
             (camera, "camera"), (present, "present"), (options, "options"), (hang, "hang up")]
        }

        var offered: [String] { named.filter { !$0.0.isHidden }.map(\.1) }

        /// What each command on offer says it will do, for the bench.
        var looks: [String: String] {
            Dictionary(uniqueKeysWithValues: named.filter { !$0.0.isHidden }.map { ($0.1, $0.0.toolTip ?? "") })
        }

        /// Each command as the page has it now.
        func show(_ state: State) {
            self.state = state
            look(microphone, state.microphone, off: "muted",
                 symbols: ("mic.fill", "mic.slash.fill"), size: 15,
                 labels: ("Mute the microphone", "Unmute the microphone"))
            look(camera, state.camera, off: "off",
                 symbols: ("video.fill", "video.slash.fill"), size: 14,
                 labels: ("Turn the camera off", "Turn the camera on"))
            // Presenting and a raised hand are on when lit, not when red:
            // neither is something gone wrong.
            present.isHidden = state.present == nil
            let presenting = state.present == "on"
            present.image = Grip.glyph(presenting ? "rectangle.on.rectangle.slash" : "rectangle.on.rectangle", 14,
                                       ink: presenting ? Palette.Film.litInk : Palette.Film.ink)
            present.layer?.backgroundColor = (presenting ? Palette.Film.lit : Palette.Film.button).cgColor
            name(present, presenting ? "Stop presenting" : "Present your screen")
            // The options are the page's own, and only while it has one.
            options.isHidden = state.hand == nil
            let raised = state.hand == "up"
            options.image = Grip.glyph(raised ? "hand.raised.fill" : "ellipsis", 15,
                                       ink: raised ? Palette.Film.litInk : Palette.Film.ink)
            options.layer?.backgroundColor = (raised ? Palette.Film.lit : Palette.Film.button).cgColor
            name(options, raised ? "More options, hand raised" : "More options")
            hang.isHidden = !state.leave
            needsLayout = true
        }

        /// A toggle that is red while it is off: a microphone or a camera
        /// someone else cannot hear or see.
        private func look(
            _ button: NSButton, _ value: String?, off: String,
            symbols: (on: String, off: String), size: CGFloat, labels: (on: String, off: String)
        ) {
            button.isHidden = value == nil
            let isOff = value == off
            button.image = Grip.glyph(isOff ? symbols.off : symbols.on, size)
            button.layer?.backgroundColor = (isOff ? Palette.Film.hangUp : Palette.Film.button).cgColor
            name(button, isOff ? labels.off : labels.on)
        }

        private func name(_ button: NSButton, _ label: String) {
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }

        override func layout() {
            super.layout()
            back.frame = NSRect(x: bounds.width - 44, y: bounds.height - 44, width: 30, height: 30)
            minimize.frame = back.frame.offsetBy(dx: -(back.frame.width + Metrics.mediaGap), dy: 0)

            // The commands the page has, centred in the band, in Meet's order.
            let shown = commands.filter { !$0.isHidden }
            let side: CGFloat = 40, gap: CGFloat = 10
            let width = CGFloat(shown.count) * side + CGFloat(max(0, shown.count - 1)) * gap
            var x = (bounds.width - width) / 2
            for button in shown {
                button.frame = NSRect(x: x, y: (Meeting.band - side) / 2, width: side, height: side)
                x += side + gap
            }
        }

        override func mouseEntered(with event: NSEvent) { fade(to: 1) }
        override func mouseExited(with event: NSEvent) { fade(to: 0) }

        private func fade(to value: CGFloat) {
            near = value > 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                [back, minimize].forEach { $0.animator().alphaValue = value }
            }
        }

        @objc private func pressedReturn() { onReturn?() }
        @objc private func pressedMinimize() { onMinimize?() }
        @objc private func pressedMicrophone() { onPress?("microphone") }
        @objc private func pressedCamera() { onPress?("camera") }
        @objc private func pressedPresent() { onPress?("present") }
        @objc private func pressedHangUp() { onPress?("leave") }

        @objc private func pressedOptions() {
            let menu = NSMenu()
            if let hand = state.hand {
                let item = NSMenuItem(title: hand == "up" ? "Lower hand" : "Raise hand",
                                      action: #selector(pressedHand), keyEquivalent: "")
                item.target = self
                item.image = NSImage(systemSymbolName: "hand.raised", accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: options.bounds.height + 4), in: options)
        }

        @objc private func pressedHand() { onPress?("hand") }
    }
}
