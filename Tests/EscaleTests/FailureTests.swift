// Every code reads as a sentence: the common ones as their own, the rest as
// the general one, never as nothing.
import Foundation
import Testing
@testable import Escale

@Suite struct FailureTests {
    @Test(arguments: [
        (NSURLErrorCannotFindHost, "No site at that address."),
        (NSURLErrorCannotConnectToHost, "The site refused the connection."),
        (NSURLErrorServerCertificateHasBadDate, "The site's certificate has expired."),
        (NSURLErrorServerCertificateNotYetValid, "The site's certificate isn't valid yet."),
        (NSURLErrorServerCertificateUntrusted, "The connection isn't secure."),
        (NSURLErrorBadServerResponse, "The site sent an answer that couldn't be read."),
        (NSURLErrorHTTPTooManyRedirects, "The site keeps sending the page somewhere else."),
    ])
    func commonCodesHaveTheirOwnSentence(code: Int, message: String) {
        #expect(Failure.message(code: code) == message)
    }

    @Test(arguments: [NSURLErrorUnknown, NSURLErrorZeroByteResource, 0, 404])
    func otherCodesFallBackToTheGeneralOne(code: Int) {
        #expect(Failure.message(code: code) == "The page didn't load.")
    }
}
