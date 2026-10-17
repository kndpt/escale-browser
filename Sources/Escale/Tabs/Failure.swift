// What a page that never arrived says about itself: the cause in a sentence,
// the address that did not answer and WebKit's own code. A developer reads
// the code; everyone else reads the sentence, so a code without its own
// sentence still gets the general one rather than none.
import Foundation

enum Failure {
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
