// Speech options are checked without starting audio or loading application state.
// The app scenario covers playback and unloading through the real extension shim.
import AVFoundation
import Testing
@testable import Escale

@Suite @MainActor struct ExtensionSpeechTests {
    @Test func defaultAndRelativeRatesStayWithinPlatformBounds() throws {
        let normal = try ExtensionSpeech.utterance("Hello", options: [:])
        #expect(normal.rate == AVSpeechUtteranceDefaultSpeechRate)
        let slow = try ExtensionSpeech.utterance("Hello", options: ["rate": 0.1])
        let fast = try ExtensionSpeech.utterance("Hello", options: ["rate": 10.0])
        #expect(slow.rate >= AVSpeechUtteranceMinimumSpeechRate)
        #expect(slow.rate < normal.rate)
        #expect(fast.rate > normal.rate)
        #expect(fast.rate <= AVSpeechUtteranceMaximumSpeechRate)
    }

    @Test func invalidRatesAndOversizedTextAreRefused() {
        for rate in [Double.nan, .infinity, -1, 0, 10.1] {
            #expect(throws: ExtensionSpeech.Refused.self) {
                try ExtensionSpeech.utterance("Hello", options: ["rate": rate])
            }
        }
        #expect(throws: ExtensionSpeech.Refused.self) {
            try ExtensionSpeech.utterance(String(repeating: "a", count: 32_769), options: [:])
        }
        // Surrogate pairs must not double the declared bound.
        #expect(throws: ExtensionSpeech.Refused.self) {
            try ExtensionSpeech.utterance(String(repeating: "😀", count: 16_385), options: [:])
        }
    }

    @Test func missingVoiceFallsBackAndBoundaryTextIsAccepted() throws {
        let utterance = try ExtensionSpeech.utterance(String(repeating: "a", count: 32_768),
                                                      options: ["voiceName": "Escale nonexistent voice"])
        #expect(utterance.voice == nil)
        #expect(utterance.speechString.utf16.count == 32_768)
    }
}
