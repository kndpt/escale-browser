// What a page that never arrived says about itself: the cause in a sentence,
// the address that did not answer and WebKit's own code. A developer reads
// the code; everyone else reads the sentence, so a code without its own
// sentence still gets the general one rather than none.
//
// A refused connection to this Mac is a dev server that isn't running yet.
// While its error page is on screen, the socket table (Listening.swift) is
// read every few seconds, never the port itself, and the page comes back
// once something listens there. A server started with sudo stays invisible
// to that reading, so the sentence promises no reload.
import Foundation

enum Failure {
    static func message(code: Int, at url: URL?) -> String {
        if waits(code: code, at: url), let port = localPort(url) { return "Nothing is listening on :\(port)." }
        return message(code: code)
    }

    /// A refused connection to this Mac: worth waiting for its server.
    static func waits(code: Int, at url: URL?) -> Bool {
        code == NSURLErrorCannotConnectToHost && localPort(url) != nil
    }

    /// The port of an address on this Mac, the scheme's own when none is written.
    static func localPort(_ url: URL?) -> Int? {
        guard let url, let host = url.host(), Dialogs.isLoopback(host) else { return nil }
        return url.port ?? ["http": 80, "https": 443][url.scheme?.lowercased() ?? ""]
    }

    /// Whether a reading of the socket table has a server at this address;
    /// an unreadable table has none.
    static func listened(_ url: URL, in listening: Listening?) -> Bool {
        listening?.serves(origin: url.absoluteString) ?? false
    }

    static func message(code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorServerCertificateHasBadDate:
            return "The site's certificate has expired."
        case NSURLErrorServerCertificateNotYetValid:
            return "The site's certificate isn't valid yet."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot:
            return "The connection isn't secure."
        case NSURLErrorBadServerResponse:
            return "The site sent an answer that couldn't be read."
        case NSURLErrorHTTPTooManyRedirects:
            return "The site keeps sending the page somewhere else."
        default:
            return "The page didn't load."
        }
    }
}
