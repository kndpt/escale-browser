// Screen captures usually carry text and code. Give WebKit that content hint
// before the site attaches the track to WebRTC, so adaptation can prefer detail.
// The page owns the capture and can replace the hint; Escale retains no stream.

import WebKit

enum ScreenShare {
    static let script = WKUserScript(
        source: Bundled.script("screen-share.js"),
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false,
        in: .page
    )
}
