import Foundation
import KITTCore
#if canImport(AVFoundation)
import AVFoundation
#endif
#if os(watchOS)
import WatchKit
#endif

/// A voice installed on the watch.
struct VoiceOption: Identifiable, Equatable {
    let id: String       // AVSpeechSynthesisVoice.identifier
    let name: String
    let detail: String   // "en-US · Enhanced"
}

/// Reads KITT's replies aloud with the watch's built-in voices, offline.
///
/// A reply is spoken as segments (SpokenReply) with silences between them: an urgent
/// reply's first instruction starts with a wrist tap and is followed by a pause; the
/// choices come after a pause. Each segment is queued only when the previous one has
/// finished and its pause has run, so Stop during a pause leaves the rest unsaid.
///
/// Other audio (a podcast) is turned down while KITT speaks and given back when it
/// finishes or is stopped. Speech keeps going with the wrist lowered or another screen
/// open; it stops on Stop, on any new reply, on New conversation, or when read-aloud is
/// turned off.
@MainActor
final class ReplySpeaker: NSObject {
    /// Called on the main actor when a reply starts and when it ends (finished or stopped).
    var onSpeakingChanged: ((Bool) -> Void)?
    /// A reply is under way, its pauses included.
    private(set) var isActive = false

    private var queue: [SpokenSegment] = []
    private var pendingPause: DispatchWorkItem?
    private var pauseAfterCurrent: Double = 0
    private var voiceID: String?
    private var rate: Float = 0.5
    /// An urgent reply's wrist tap, waiting for its first word.
    private var pendingTap: DispatchWorkItem?

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    private var preview: AVAudioPlayer?
    private var previewFailure: (() -> Void)?
    private var current: AVSpeechUtterance?
    static let normalRate = AVSpeechUtteranceDefaultSpeechRate
    static let slowerRate = AVSpeechUtteranceDefaultSpeechRate * 0.85
    #endif

    /// Speak a reply from the beginning, replacing anything being said.
    func speak(_ reply: SpokenReply, voiceID: String?, slower: Bool) {
        let segments = reply.segments.filter { !$0.text.isEmpty }
        guard !segments.isEmpty else { stop(); return }
        #if canImport(AVFoundation)
        let wasActive = isActive
        halt()
        if !wasActive { startAudio() }
        self.voiceID = voiceID
        rate = slower ? Self.slowerRate : Self.normalRate
        if synthesizer.delegate == nil { synthesizer.delegate = self }
        queue = segments
        isActive = true
        if !wasActive { onSpeakingChanged?(true) }
        speakNext()
        // The wrist tap and the first instruction start together: the tap waits for the
        // voice to start (didStart), or half a second if that never comes.
        if reply.urgent {
            let tap = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.firePendingTap() }
            }
            pendingTap = tap
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: tap)
        }
        #endif
    }

    func stop() {
        guard isActive else { return }
        halt()
        isActive = false
        endAudio()
        onSpeakingChanged?(false)
    }

    /// Audition a local recording through the same audio session and Stop control.
    func playPreview(_ url: URL, slower: Bool, urgent: Bool = false, onDecodeFailure: (() -> Void)? = nil) -> Bool {
        #if canImport(AVFoundation)
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return false }
        return play(player, slower: slower, urgent: urgent, onDecodeFailure: onDecodeFailure)
        #else
        return false
        #endif
    }

    /// Play a guide recording from a voice pack through the same audio session and Stop
    /// control. false: it couldn't start, so the caller has the Apple voice read instead.
    func playRecording(_ data: Data, urgent: Bool = false, onDecodeFailure: (() -> Void)? = nil) -> Bool {
        #if canImport(AVFoundation)
        guard let player = try? AVAudioPlayer(data: data, fileTypeHint: AVFileType.mp3.rawValue) else { return false }
        return play(player, slower: false, urgent: urgent, onDecodeFailure: onDecodeFailure)
        #else
        return false
        #endif
    }

    #if canImport(AVFoundation)
    private func play(_ player: AVAudioPlayer, slower: Bool, urgent: Bool, onDecodeFailure: (() -> Void)?) -> Bool {
        let wasActive = isActive
        halt()
        if !wasActive { startAudio() }
        player.delegate = self
        player.enableRate = slower
        if slower { player.rate = 0.85 }
        preview = player
        previewFailure = onDecodeFailure
        guard player.play() else {
            stopPreview()
            isActive = false
            endAudio()
            if wasActive { onSpeakingChanged?(false) }
            return false
        }
        isActive = true
        if !wasActive { onSpeakingChanged?(true) }
        if urgent { Self.tapWrist() }
        return true
    }
    #endif

    /// Cancels the scheduled pause, the queue and the current utterance.
    private func halt() {
        pendingPause?.cancel()
        pendingPause = nil
        pendingTap?.cancel()
        pendingTap = nil
        queue = []
        #if canImport(AVFoundation)
        let hasUtterance = current != nil
        stopPreview()
        current = nil
        if hasUtterance { synthesizer.stopSpeaking(at: .immediate) }
        #endif
    }

    private func finish() {
        guard isActive else { return }
        isActive = false
        pendingPause = nil
        pendingTap?.cancel()
        pendingTap = nil
        #if canImport(AVFoundation)
        current = nil
        #endif
        endAudio()
        onSpeakingChanged?(false)
    }

    #if canImport(AVFoundation)
    private func stopPreview() {
        previewFailure = nil
        preview?.delegate = nil
        preview?.stop()
        preview = nil
    }

    private func speakNext() {
        guard isActive else { return }
        guard !queue.isEmpty else { finish(); return }
        let segment = queue.removeFirst()
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.rate = rate
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) { utterance.voice = voice }
        pauseAfterCurrent = segment.pauseAfter
        current = utterance
        synthesizer.speak(utterance)
    }

    fileprivate func started(_ id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id else { return }
        firePendingTap()
    }

    fileprivate func finished(_ id: ObjectIdentifier) {
        guard isActive, let current, ObjectIdentifier(current) == id else { return }
        self.current = nil
        guard !queue.isEmpty else { finish(); return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.speakNext() }
        }
        pendingPause = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseAfterCurrent, execute: work)
    }

    fileprivate func cancelled(_ id: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == id else { return }
        queue.removeAll()
        finish()
    }

    private func startAudio() {
        let session = AVAudioSession.sharedInstance()
        // Turn other audio down rather than stopping it. If the watch refuses ducking,
        // fall back to the setting that worked before (other audio pauses, then resumes).
        do {
            try session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers])
        } catch {
            try? session.setCategory(.playback, mode: .voicePrompt, options: [])
        }
        try? session.setActive(true)
    }

    /// Give the audio back so other apps return to their volume or resume. The short
    /// delay lets the synthesizer release its output first; a new reply cancels it.
    private func endAudio() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isActive else { return }
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
    #else
    private func endAudio() {}
    #endif

    private func firePendingTap() {
        guard let tap = pendingTap else { return }
        tap.cancel()
        pendingTap = nil
        Self.tapWrist()
    }

    private static func tapWrist() {
        #if os(watchOS)
        WKInterfaceDevice.current().play(.notification)
        #endif
    }

    /// Voices for the watch's language, best quality first. Novelty and Eloquence voices
    /// are left out.
    static func availableVoices() -> [VoiceOption] {
        #if canImport(AVFoundation)
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) }
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.identifier.contains("eloquence") }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                if (a.language == language) != (b.language == language) { return a.language == language }
                return a.name < b.name
            }
            .map { VoiceOption(id: $0.identifier, name: $0.name, detail: "\($0.language) · \(qualityName($0.quality.rawValue))") }
        #else
        return []
        #endif
    }

    private static func qualityName(_ raw: Int) -> String {
        switch raw {
        case 3: return "Premium"
        case 2: return "Enhanced"
        default: return "Standard"
        }
    }
}

#if canImport(AVFoundation)
extension ReplySpeaker: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        endPreview(player, success: flag)
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        endPreview(player, success: false)
    }

    private nonisolated func endPreview(_ player: AVAudioPlayer, success: Bool) {
        Task { @MainActor in
            guard self.preview === player else { return }
            let fallback = self.previewFailure
            self.previewFailure = nil
            self.preview = nil
            if !success, let fallback { fallback(); return }
            self.finish()
        }
    }
}

extension ReplySpeaker: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.cancelled(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.started(id) } }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.finished(id) } }
    }
}
#endif
