import Foundation
import SwiftUI
import KITTCore
import KITTEngine

/// One row in the conversation list, derived from saved events.
struct DisplayTurn: Identifiable, Equatable {
    enum Kind: Equatable { case user, assistant(AssistantMessage), note }
    let id: UUID
    let kind: Kind
    let text: String
    var calculation: WaterCalculation? = nil
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var turns: [DisplayTurn] = []
    @Published private(set) var household = HouseholdState()
    @Published private(set) var activeHazards: [GuideEntry] = []
    @Published private(set) var streamingText: String?
    @Published private(set) var status: String?
    @Published private(set) var isGenerating = false
    @Published private(set) var lastBenchmark: String?
    /// The verified offline model, if one is downloaded (More › Offline model).
    @Published private(set) var installedModel: InstalledModel?
    @Published private(set) var modelPhase: ModelDownloader.Phase = .idle
    /// Speak each reply as it arrives. On by default; More › Read replies aloud.
    @Published var readAloud: Bool {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: Self.readAloudKey)
            if !readAloud { speaker.stop() }
        }
    }
    /// A reply is being read aloud, its pauses included: every screen shows the stop square.
    @Published private(set) var isSpeaking = false
    /// More › Voice. nil is the watch's default voice.
    @Published var voiceID: String? {
        didSet { UserDefaults.standard.set(voiceID, forKey: Self.voiceKey) }
    }
    /// More › Voice › Reply voice. Heart or Michael reads only once its pack is downloaded;
    /// until then, and for replies it has no recording of, the Apple voice reads.
    @Published var guideVoice: GuideVoice {
        didSet { UserDefaults.standard.set(guideVoice.rawValue, forKey: Self.guideVoiceKey) }
    }
    /// Guide voice packs downloaded and verified on this watch.
    @Published private(set) var installedVoices: Set<GuideVoice> = []
    /// Each voice pack's download.
    @Published private(set) var voicePhases: [GuideVoice: ModelDownloader.Phase] = [:]
    /// More › Voice › Speed: Normal or Slower.
    @Published var slowerSpeech: Bool {
        didSet { UserDefaults.standard.set(slowerSpeech, forKey: Self.slowerKey) }
    }
    /// When and from which commit this build was made (scripts/stamp-build.sh), shown at
    /// the bottom of More so it's easy to tell which build is on the watch.
    static let buildLabel: String = (Bundle.main.object(forInfoDictionaryKey: "KITTBuild") as? String)
        .map { "Built " + $0 } ?? "Development build"
    /// The line every voice reads under More › Voice, so voices can be compared by ear.
    static let voiceSample = SpeechText.voiceSample
    private static let readAloudKey = "kitt.readAloud"
    private static let voiceKey = "kitt.voiceID"
    private static let guideVoiceKey = "kitt.guideVoice"
    private static let slowerKey = "kitt.slowerSpeech"
    private let speaker = ReplySpeaker()
    private let downloads = ModelDownloader.shared
    /// Installed voice packs, opened on first use, and which file each was opened from.
    private var openVoicePacks: [GuideVoice: VoicePack] = [:]
    private var installedVoiceIDs: [GuideVoice: String] = [:]

    let session: KITTSession
    let metrics: MetricsRecorder
    private let holder = EngineHolder()
    private let engineQueue = DispatchQueue(label: "kitt.engine", qos: .userInitiated)
    private let launchedAt = Date()

    var pack: ContentPack { session.pack }

    init() {
        readAloud = UserDefaults.standard.object(forKey: Self.readAloudKey) as? Bool ?? true
        voiceID = UserDefaults.standard.string(forKey: Self.voiceKey)
        guideVoice = UserDefaults.standard.string(forKey: Self.guideVoiceKey).flatMap(GuideVoice.init(rawValue:)) ?? .system
        slowerSpeech = UserDefaults.standard.bool(forKey: Self.slowerKey)
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KITT", isDirectory: true)
        metrics = MetricsRecorder(fileURL: support.appendingPathComponent("metrics.jsonl"))
        do {
            let log = try EventLog(fileURL: support.appendingPathComponent("events.jsonl"), device: Self.deviceID())
            session = KITTSession(log: log, pack: try ContentPack.bundled())
            if log.skippedLines > 0 { status = "Skipped \(log.skippedLines) unreadable record(s)." }
        } catch {
            // Without storage KITT cannot keep its promises; fail loudly in development.
            fatalError("KITT storage unavailable: \(error)")
        }
        speaker.onSpeakingChanged = { [weak self] speaking in self?.isSpeaking = speaking }
        downloads.onChange = { [weak self] in self?.offlineModelChanged() }
        installedModel = downloads.store?.installed
        modelPhase = downloads.phase
        session.modelAvailable = installedModel != nil
        for voice in GuideVoice.recorded {
            voice.downloader?.onChange = { [weak self] in self?.voicePackChanged(voice) }
            voicePackChanged(voice)
        }
        refresh()
        metrics.record("app_init", ["events": Double(session.log.all.count)])
    }

    // MARK: Actions

    /// Free text from Scribble, dictation, or a keyboard.
    func send(_ text: String, via method: InputMethod) {
        handle { try self.session.send(text, via: method) }
    }

    /// A tapped guide entry (topic list or a button under an answer).
    func ask(entryID: String) {
        handle { try self.session.ask(entryID: entryID) }
    }

    /// The user accepts an unverified model reply to the question the guide did not cover.
    func askModelAnyway() {
        guard !isGenerating, installedModel != nil,
              let request = session.modelRequestForUnansweredQuestion() else { return }
        runModel(request)
    }

    /// "This applies to us" under a warning KITT showed as a precaution.
    func confirmHazard(_ entryID: String) {
        speaker.stop()
        do { try session.confirmHazard(entryID); refresh() }
        catch { status = "Could not save: \(error.localizedDescription)" }
    }

    func clearHazard(_ entryID: String) {
        do { try session.clearHazard(entryID); refresh() }
        catch { status = "Could not save: \(error.localizedDescription)" }
    }

    /// Save household edits. If KITT was waiting for one of them, answer the question now.
    func setFacts(_ facts: [(HouseholdFact.Key, Double)]) {
        guard !facts.isEmpty else { return }
        do {
            for (key, value) in facts { try session.setFact(key, value) }
            if case let .assistant(last)? = turns.last?.kind, last.needsFact != nil,
               let entry = last.citations.first.flatMap({ pack.entry(forCitation: $0) }) {
                _ = try session.ask(entryID: entry.id)
            }
            refresh()
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }

    func newConversation() {
        guard !isGenerating else { return }
        speaker.stop()
        session.startNewConversation()
        refresh()
    }

    func cancelGeneration() { holder.engine?.cancel() }

    /// The Stop speaking button.
    func stopSpeaking() { speaker.stop() }

    func firstAppear() {
        metrics.record("first_frame", ["ms_since_init": Date().timeIntervalSince(launchedAt) * 1000])
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        let name: String
        switch phase {
        case .active: name = "active"
        case .inactive: name = "inactive"   // wrist lowered or system overlay
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        metrics.record("scene_" + name, ["generating": isGenerating ? 1 : 0])
        // Do not generate in the background. The partial reply is saved as interrupted.
        if phase == .background { holder.engine?.cancel() }
    }

    private func handle(_ turn: () throws -> TurnOutcome) {
        guard !isGenerating else { return }
        speaker.stop()
        do {
            let outcome = try turn()
            refresh()  // the user's turn is on disk and on screen before any model runs
            switch outcome {
            case let .needsModel(request): runModel(request)
            case let .answered(message): speak(message)
            }
        } catch KITTError.emptyMessage {
            return
        } catch {
            status = "Could not save: \(error.localizedDescription)"
        }
    }

    // MARK: Speech

    /// A new reply, read aloud when read-aloud is on.
    private func speak(_ message: AssistantMessage) {
        guard readAloud else { return }
        readAgain(message)
    }

    /// Read a reply from the beginning, read-aloud on or off (the Read again button).
    /// SpeechText splits it into segments with pauses and offers only the choices that are
    /// buttons on the answer screen, so it can be answered without looking.
    func readAgain(_ message: AssistantMessage) {
        let reply = SpeechText.reply(for: message, pack: pack, activeHazards: session.state.activeHazards)
        playReply(reply, useRecording: message.origin != .model)
    }

    private func playReply(_ reply: SpokenReply, useRecording: Bool) {
        let speakOnWatch = { [speaker, voiceID, slowerSpeech] in
            speaker.speak(reply, voiceID: voiceID, slower: slowerSpeech)
        }
        // A Slower recording was recorded slower, so it plays at its own speed.
        if useRecording, let data = recording(for: reply),
           speaker.playRecording(data, urgent: reply.urgent, onDecodeFailure: speakOnWatch) { return }
        speakOnWatch()
    }

    /// The chosen voice's recording of exactly this reply at the chosen speed, if its pack
    /// is installed and has one.
    private func recording(for reply: SpokenReply) -> Data? {
        guard installedVoices.contains(guideVoice) else { return nil }
        return voicePack(guideVoice)?.clip(for: reply, slower: slowerSpeech)
    }

    private func voicePack(_ voice: GuideVoice) -> VoicePack? {
        if let open = openVoicePacks[voice] { return open }
        guard let url = voice.downloader?.store?.installedURL,
              let pack = try? VoicePack(contentsOf: url), pack.voice == voice.rawValue else { return nil }
        openVoicePacks[voice] = pack
        return pack
    }

    /// The voices installed for the watch's language, best first.
    var voiceOptions: [VoiceOption] { ReplySpeaker.availableVoices() }

    /// Play the sample line with the chosen voice and speed.
    func playVoiceSample() {
        playReply(SpokenReply(segments: [SpokenSegment(Self.voiceSample)]), useRecording: true)
    }

    func playRecordedSample(_ resource: String, fileExtension: String = "wav") -> Bool {
        guard let url = Bundle.main.url(forResource: resource, withExtension: fileExtension) else { return false }
        return speaker.playPreview(url, slower: slowerSpeech)
    }

    // MARK: Offline model

    /// What this build downloads, from its Info.plist. nil: the build offers no model.
    var modelManifest: ModelManifest? { downloads.store?.manifest }

    /// A verified model is installed, but this build pins a different one.
    var modelHasUpdate: Bool { downloads.store?.hasUpdate ?? false }

    /// A stopped download can continue from where it stopped.
    var canResumeModelDownload: Bool { downloads.store?.hasResumeData ?? false }

    /// One line for the More list.
    var modelSummary: String {
        switch modelPhase {
        case let .downloading(received, total):
            return total > 0 ? "Downloading \(Int(100 * Double(received) / Double(total)))%" : "Downloading"
        case .verifying: return "Checking the download"
        case .paused: return canResumeModelDownload ? "Paused" : "Download stopped"
        case .failed: return "Download stopped"
        case .idle: break
        }
        if installedModel != nil { return modelHasUpdate ? "Ready · update available" : "Ready offline" }
        return modelManifest.map { "Optional · \($0.sizeLabel)" } ?? "Not in this build"
    }

    func downloadModel() { downloads.start() }

    func cancelModelDownload() { downloads.cancel() }

    func deleteModel() {
        guard !isGenerating else { return }
        do { try downloads.delete() }
        catch { status = "Could not delete the model: \(error.localizedDescription)" }
    }

    /// A model arrived, was replaced or was deleted, or the download moved on.
    private func offlineModelChanged() {
        let installed = downloads.store?.installed
        if installed?.id != installedModel?.id {
            // Release the old engine once any reply in progress has finished with it.
            let holder = self.holder
            engineQueue.async { holder.engine = nil }
        }
        installedModel = installed
        modelPhase = downloads.phase
        session.modelAvailable = installed != nil
    }

    // MARK: Guide voices

    /// This build's pack for a voice, from its Info.plist. nil: the build offers none.
    func voiceManifest(_ voice: GuideVoice) -> ModelManifest? { voice.downloader?.store?.manifest }

    /// A verified pack is installed, but this build pins a different one (new recordings).
    func voiceHasUpdate(_ voice: GuideVoice) -> Bool { voice.downloader?.store?.hasUpdate ?? false }

    func canResumeVoiceDownload(_ voice: GuideVoice) -> Bool { voice.downloader?.store?.hasResumeData ?? false }

    func voicePhase(_ voice: GuideVoice) -> ModelDownloader.Phase { voicePhases[voice] ?? .idle }

    /// One line for the Voice list.
    func voiceSummary(_ voice: GuideVoice) -> String {
        switch voicePhase(voice) {
        case let .downloading(received, total):
            return total > 0 ? "Downloading \(Int(100 * Double(received) / Double(total)))%" : "Downloading"
        case .verifying: return "Checking the download"
        case .paused: return canResumeVoiceDownload(voice) ? "Paused" : "Download stopped"
        case .failed: return "Download stopped"
        case .idle: break
        }
        if installedVoices.contains(voice) { return voiceHasUpdate(voice) ? "Ready · update available" : "Ready" }
        return voiceManifest(voice).map { "Download · \($0.sizeLabel)" } ?? "Not in this build"
    }

    func downloadVoice(_ voice: GuideVoice) { voice.downloader?.start() }

    func cancelVoiceDownload(_ voice: GuideVoice) { voice.downloader?.cancel() }

    /// Remove a voice pack. If it was the reply voice, the Apple voice takes over.
    func deleteVoice(_ voice: GuideVoice) {
        if guideVoice == voice { guideVoice = .system }
        do { try voice.downloader?.delete() }
        catch { status = "Could not delete the \(voice.rawValue) voice: \(error.localizedDescription)" }
    }

    private func voicePackChanged(_ voice: GuideVoice) {
        guard let downloader = voice.downloader else { return }
        let installed = downloader.store?.installed
        if installed?.id != installedVoiceIDs[voice] {
            // A new, updated or deleted pack: open the current file next time.
            openVoicePacks[voice] = nil
            installedVoiceIDs[voice] = installed?.id
        }
        if installed != nil { installedVoices.insert(voice) } else { installedVoices.remove(voice) }
        voicePhases[voice] = downloader.phase
    }

    // MARK: Model

    private func runModel(_ request: ModelRequest) {
        isGenerating = true
        streamingText = ""
        status = holder.engine == nil ? "Loading model…" : nil
        let session = self.session, metrics = self.metrics, holder = self.holder
        engineQueue.async { [weak self] in
            var text = ""
            var stats: GenerationStats?
            var modelID = "unloaded"
            var failure: Error?
            let sampler = metrics.startMemorySampler()
            let battery0 = metrics.batteryLevel()
            do {
                let engine = try Self.loadEngine(holder: holder, metrics: metrics)
                modelID = engine.modelID
                Self.onMain { self?.status = nil }
                stats = try engine.generate(request.prompt) { piece in
                    text += piece
                    let snapshot = text
                    Self.onMain { self?.streamingText = snapshot }
                }
            } catch {
                failure = error
            }
            let peak = sampler.stop()
            let interrupted = stats?.stop == .cancelled || failure != nil
            let saved = text.isEmpty ? (failure.map { "Model error: \($0)" } ?? "(no reply)") : text
            // Save even partial replies so the record matches what was on screen.
            let recorded = try? session.recordModelReply(saved, for: request, modelID: modelID, interrupted: interrupted)
            if let stats { metrics.record(generation: stats, peakFootprintMB: peak, batteryStart: battery0) }
            Self.onMain {
                guard let self else { return }
                self.streamingText = nil
                self.isGenerating = false
                if let failure { self.status = "\(failure)" }
                self.refresh()
                if failure == nil, !text.isEmpty, let recorded { self.speak(recorded) }
            }
        }
    }

    /// Fixed prompt, outside the conversation, for comparable measurements.
    func runBenchmark() {
        guard !isGenerating else { return }
        guard installedModel != nil else {
            lastBenchmark = "Download the offline model first: More › Offline model."
            return
        }
        isGenerating = true
        lastBenchmark = holder.engine == nil ? "Loading model…" : "Running…"
        let metrics = self.metrics, holder = self.holder
        engineQueue.async { [weak self] in
            let line: String
            let sampler = metrics.startMemorySampler()
            let battery0 = metrics.batteryLevel()
            do {
                let engine = try Self.loadEngine(holder: holder, metrics: metrics)
                let stats = try engine.generate(Benchmark.prompt) { _ in }
                let peak = sampler.stop()
                metrics.record(generation: stats, peakFootprintMB: peak, batteryStart: battery0)
                line = String(format: "First word %.1f s\n%.1f tok/s (%d tokens)\nPrompt %d tok, %d reused, %.0f tok/s\nPeak %.0f MB",
                              (stats.timeToFirstTokenMilliseconds ?? 0) / 1000, stats.tokensPerSecond, stats.generatedTokens,
                              stats.promptTokens, stats.reusedTokens, stats.prefillTokensPerSecond, peak)
            } catch {
                _ = sampler.stop()
                line = "Failed: \(error)"
            }
            let result = line
            Self.onMain {
                self?.lastBenchmark = result
                self?.isGenerating = false
            }
        }
    }

    /// Runs on engineQueue. Loads once, then reuses. The fixed system text is evaluated
    /// right after loading so the first question does not pay for it.
    nonisolated private static func loadEngine(holder: EngineHolder, metrics: MetricsRecorder) throws -> LlamaEngine {
        guard let model = ModelLocator.installed() else { throw ModelLocator.NotDownloaded() }
        if let e = holder.engine, e.modelID == model.id { return e }
        holder.engine = nil   // a replaced model: free the old one before loading the new
        let before = MetricsRecorder.footprintMB()
        let engine = try LlamaEngine(modelURL: model.url, modelID: model.id)
        let loaded = Date()
        try? engine.prewarm(Benchmark.prompt)
        metrics.record("model_load", [
            "ms": engine.loadMilliseconds,
            "prewarm_ms": Date().timeIntervalSince(loaded) * 1000,
            "footprint_before_mb": before,
            "footprint_after_mb": MetricsRecorder.footprintMB(),
            "available_mb": MetricsRecorder.availableMB(),
        ])
        holder.engine = engine
        return engine
    }

    /// Ordered hop to the main actor (unlike spawning a Task per token).
    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    // MARK: Display

    func refresh() {
        household = session.household
        activeHazards = session.state.activeHazards.compactMap { pack.entry($0) }
        var previousCalculation: WaterCalculation?
        turns = session.events.compactMap { e in
            let calculation = previousCalculation
            previousCalculation = nil
            switch e.payload {
            case let .userMessage(text, _): return DisplayTurn(id: e.id, kind: .user, text: text)
            case let .assistantMessage(m):
                let matched = calculation.flatMap { m.citations.contains($0.guideCitation) ? $0 : nil }
                return DisplayTurn(id: e.id, kind: .assistant(m), text: m.text, calculation: matched)
            case let .householdFact(f): return DisplayTurn(id: e.id, kind: .note, text: Self.describe(f))
            case let .condition(c):
                let label = pack.entry(c.entryID)?.hazard?.label ?? c.entryID
                return DisplayTurn(id: e.id, kind: .note, text: c.state.title + ": " + label)
            case let .waterNotice(n):
                return DisplayTurn(id: e.id, kind: .note, text: n.title)
            case let .calculation(value):
                previousCalculation = value
                return nil
            }
        }
    }

    /// Whether "This applies to us" belongs under this row: it showed a hazard as a
    /// precaution and that hazard is not flagged yet.
    func canConfirmHazard(under turn: DisplayTurn) -> String? {
        guard case let .assistant(m) = turn.kind, let id = m.suggestedHazard else { return nil }
        return activeHazards.contains { $0.id == id } ? nil : id
    }

    /// Whether the "Ask the model anyway" button belongs under this row.
    func canAskModel(under turn: DisplayTurn) -> Bool {
        guard !isGenerating, installedModel != nil, turn.id == turns.last?.id,
              case let .assistant(m) = turn.kind else { return false }
        return m.offersModel
    }

    private static func describe(_ f: HouseholdFact) -> String {
        switch f.key {
        case .people: return "Household: \(People(Int(f.value)).label)"
        case .storedWater: return "Water on hand: \(USGallons(f.value).label)"
        case .planDays: return "Plan length: \(Days(Int(f.value)).label)"
        }
    }

    private static func deviceID() -> DeviceID {
        let key = "kitt.deviceID"
        if let id = UserDefaults.standard.string(forKey: key) { return DeviceID(id) }
        let id = "watch-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return DeviceID(id)
    }
}

/// Fixed prompt for comparable measurements across builds, models, and settings.
enum Benchmark {
    static let prompt = PromptBuilder.grounded(
        question: "Why should the refrigerator door stay closed?",
        passages: ["During a power outage keep refrigerator and freezer doors closed. With doors closed food stays safe about 4 hours in a refrigerator, 48 hours in a full freezer, and 24 hours in a half-full freezer."])
}

/// Engine reference shared between the main actor (cancel) and the engine queue (load/use).
final class EngineHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _engine: LlamaEngine?
    var engine: LlamaEngine? {
        get { lock.lock(); defer { lock.unlock() }; return _engine }
        set { lock.lock(); _engine = newValue; lock.unlock() }
    }
}

/// The model KITT loads: the verified download in Application Support/KITT/Models.
/// Nothing is bundled; watch apps are limited to 75 MB and the model alone is 92 MB.
enum ModelLocator {
    struct NotDownloaded: Error, CustomStringConvertible {
        var description: String { "The offline model isn't downloaded. See More › Offline model." }
    }

    /// The installed model's file and the ID saved with every model reply
    /// ("SmolLM2-135M-Instruct-Q4_0@bcc3af28").
    static func installed() -> (url: URL, id: String)? {
        guard let store = ModelDownloader.shared.store, let model = store.installed,
              let url = store.installedURL else { return nil }
        return (url, model.id)
    }

    static var describedModel: String {
        installed().map { "Offline model: \($0.id)" } ?? "Offline model: not downloaded"
    }
}
