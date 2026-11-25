import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Reads KITT's replies aloud with the watch's built-in voice. Speech is synthesized on the
/// watch, so it works offline. Turn it off under More › Read replies aloud.
///
/// Speech stops when the user taps Stop speaking, sends or taps anything else, or turns
/// read-aloud off. It keeps going with the wrist lowered, so a reply can be heard without
/// looking.
@MainActor
final class ReplySpeaker: NSObject {
    /// Called on the main actor when speech starts and when it ends (finished or stopped).
    var onSpeakingChanged: ((Bool) -> Void)?

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being spoken. A finish or cancel for an older one is ignored, so
    /// replacing one reply with the next does not hide the Stop button.
    private var current: AVSpeechUtterance?
    #endif

    func speak(_ text: String) {
        #if canImport(AVFoundation)
        stop()
        // Playback, so replies are heard even with the watch's silent mode on.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt, options: [])
        if synthesizer.delegate == nil { synthesizer.delegate = self }
        let utterance = AVSpeechUtterance(string: text)
        current = utterance
        synthesizer.speak(utterance)
        onSpeakingChanged?(true)
        #endif
    }

    func stop() {
        #if canImport(AVFoundation)
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if current != nil {
            current = nil
            onSpeakingChanged?(false)
        }
        #endif
    }

    #if canImport(AVFoundation)
    fileprivate func ended(_ id: ObjectIdentifier) {
        // A reply replaced by the next one is still "speaking" here; only the last ends it.
        guard let current, ObjectIdentifier(current) == id, !synthesizer.isSpeaking else { return }
        self.current = nil
        onSpeakingChanged?(false)
    }
    #endif
}

#if canImport(AVFoundation)
extension ReplySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.ended(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.ended(id) } }
    }
}
#endif
