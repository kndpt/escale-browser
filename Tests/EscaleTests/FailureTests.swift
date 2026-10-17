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

    @Test(arguments: [
        ("http://localhost:3000/", 3000), ("http://127.0.0.1:5173/app", 5173), ("http://[::1]:8080", 8080),
        ("http://web.localhost/", 80), ("https://localhost/", 443),
    ])
    func aRefusedLocalAddressNamesItsPort(address: String, port: Int) throws {
        let url = try #require(URL(string: address))
        #expect(Failure.waits(code: NSURLErrorCannotConnectToHost, at: url))
        #expect(Failure.message(code: NSURLErrorCannotConnectToHost, at: url) == "Nothing is listening on :\(port).")
    }

    @Test(arguments: ["http://example.com:3000/", "http://192.168.1.4:3000/", "http://127.0.0.1.example.com/", "file:///tmp/a"])
    func elsewhereARefusalIsTheSites(address: String) throws {
        let url = try #require(URL(string: address))
        #expect(!Failure.waits(code: NSURLErrorCannotConnectToHost, at: url))
        #expect(Failure.message(code: NSURLErrorCannotConnectToHost, at: url) == "The site refused the connection.")
    }

    @Test func onlyARefusalWaits() throws {
        let url = try #require(URL(string: "http://localhost:3000/"))
        #expect(!Failure.waits(code: NSURLErrorTimedOut, at: url))
        #expect(Failure.message(code: NSURLErrorTimedOut, at: url) == "The site took too long to answer.")
        #expect(!Failure.waits(code: NSURLErrorCannotConnectToHost, at: nil))
    }

    @Test func reloadsOnlyOnceItsPortListens() throws {
        let url = try #require(URL(string: "http://localhost:3000/dashboard"))
        var table = Listening()
        #expect(!Failure.listened(url, in: table))
        table.v6 = [3000]
        #expect(Failure.listened(url, in: table))
        table = Listening(v4: [3001])
        #expect(!Failure.listened(url, in: table))
        #expect(!Failure.listened(url, in: nil))
        let v4 = try #require(URL(string: "http://127.0.0.1:3000/"))
        #expect(!Failure.listened(v4, in: Listening(v6: [3000])))
        #expect(Failure.listened(v4, in: Listening(v4: [3000])))
    }
}
