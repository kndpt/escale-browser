// Extension speech has one shared playback lane, as the existing Chrome shim did.
// AVFoundation owns audio only while requested speech is pending. Keeping the
// waiting utterances here lets unloading an extension remove its work without
// interrupting another extension. At most 32 utterances of 32,768 UTF-16 units
// are retained; no timer, page or synthesizer is created by a state query.
import AVFoundation
import Foundation

@MainActor
final class ExtensionSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = ExtensionSpeech()
    static let capacity = 32
    static let textLimit = 32_768

    struct Refused: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private struct Reading {
        let scope: String
        let utterance: AVSpeechUtterance
    }

    private var synthesizer: AVSpeechSynthesizer?
    private var current: Reading?
    private var waiting: [Reading] = []
    private var started = false

    var isSpeaking: Bool { synthesizer?.isSpeaking ?? false }

    /// Diagnostics use the live owner rather than allocating audio to inspect it.
    var state: [String: Any] {
        ["active": synthesizer != nil, "speaking": isSpeaking,
         "paused": synthesizer?.isPaused ?? false, "started": started,
         "queued": waiting.count, "scope": current?.scope ?? "",
         "voiceName": current?.utterance.voice?.name ?? "",
         "rate": current?.utterance.rate ?? AVSpeechUtteranceDefaultSpeechRate]
    }

    static func voices() -> [[String: Any]] {
        AVSpeechSynthesisVoice.speechVoices().map {
            ["voiceName": $0.name, "lang": $0.language.replacingOccurrences(of: "_", with: "-"),
             "remote": false, "eventTypes": ["start", "end"]]
        }
    }

    /// AVFoundation's rate is bounded and has no words-per-minute equivalent.
    static func utterance(_ text: String, options: [String: Any]) throws -> AVSpeechUtterance {
        guard text.utf16.count <= textLimit else { throw Refused(reason: "Speech text exceeds 32,768 characters") }
        let multiplier = options["rate"] as? Double ?? 1
        guard multiplier.isFinite, (0.1...10).contains(multiplier) else {
            throw Refused(reason: "Speech rate must be between 0.1 and 10")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                             max(AVSpeechUtteranceMinimumSpeechRate,
                                 AVSpeechUtteranceDefaultSpeechRate * Swift.Float(multiplier)))
        if let name = options["voiceName"] as? String {
            utterance.voice = AVSpeechSynthesisVoice.speechVoices().first { $0.name == name }
        }
        return utterance
    }

    func speak(_ text: String, options: [String: Any], scope: String) throws {
        let utterance = try Self.utterance(text, options: options)
        let enqueue = options["enqueue"] as? Bool ?? false
        if !enqueue { stop() }
        guard !text.isEmpty else { return }
        if enqueue, waiting.count + (current == nil ? 0 : 1) >= Self.capacity {
            throw Refused(reason: "Speech queue is full (32 utterances)")
        }
        waiting.append(Reading(scope: scope, utterance: utterance))
        advance()
    }

    func pause() { synthesizer?.pauseSpeaking(at: .immediate) }
    func resume() { synthesizer?.continueSpeaking() }

    func stop() {
        waiting.removeAll()
        end()
    }

    /// Unload cancels only work submitted by that extension and Space.
    func release(scope: String) {
        waiting.removeAll { $0.scope == scope }
        if current?.scope == scope {
            end()
            advance()
        }
    }

    private func end() {
        // A cancelled synthesizer cannot complete or advance its replacement.
        let old = synthesizer
        old?.delegate = nil
        synthesizer = nil
        current = nil
        started = false
        old?.stopSpeaking(at: .immediate)
    }

    private func advance() {
        guard current == nil, !waiting.isEmpty else { return }
        current = waiting.removeFirst()
        let speaker = AVSpeechSynthesizer()
        speaker.delegate = self
        synthesizer = speaker
        if let current { speaker.speak(current.utterance) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(synthesizer)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.synthesizer.map(ObjectIdentifier.init) == identity else { return }
            self.started = true
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(synthesizer)
        DispatchQueue.main.async { [weak self] in self?.finish(identity) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let identity = ObjectIdentifier(synthesizer)
        DispatchQueue.main.async { [weak self] in self?.finish(identity) }
    }

    private func finish(_ identity: ObjectIdentifier) {
        guard synthesizer.map(ObjectIdentifier.init) == identity else { return }
        end()
        advance()
    }
}
