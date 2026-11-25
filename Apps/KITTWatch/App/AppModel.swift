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
    /// Speak each reply as it arrives. On by default; More › Read replies aloud.
    @Published var readAloud: Bool {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: Self.readAloudKey)
            if !readAloud { speaker.stop() }
        }
    }
    /// A reply is being read aloud: the conversation shows Stop speaking.
    @Published private(set) var isSpeaking = false
    private static let readAloudKey = "kitt.readAloud"
    private let speaker = ReplySpeaker()

    let session: KITTSession
    let metrics: MetricsRecorder
    private let holder = EngineHolder()
    private let engineQueue = DispatchQueue(label: "kitt.engine", qos: .userInitiated)
    private let launchedAt = Date()

    var pack: ContentPack { session.pack }

    init() {
        readAloud = UserDefaults.standard.object(forKey: Self.readAloudKey) as? Bool ?? true
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
        refresh()
        speaker.onSpeakingChanged = { [weak self] speaking in self?.isSpeaking = speaking }
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
        guard !isGenerating, let request = session.modelRequestForUnansweredQuestion() else { return }
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

    /// A reply read aloud, with the buttons under it (SpeechText), so a reply that asks
    /// "Is it running there?" or "Is it one of these?" can be answered without looking.
    private func speak(_ message: AssistantMessage) {
        guard readAloud else { return }
        speaker.speak(SpeechText.make(for: message, pack: pack, activeHazards: session.state.activeHazards))
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
        if let e = holder.engine { return e }
        let url = try ModelLocator.modelURL()
        let before = MetricsRecorder.footprintMB()
        let engine = try LlamaEngine(modelURL: url, modelID: ModelLocator.modelID(for: url))
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
        guard !isGenerating, turn.id == turns.last?.id, case let .assistant(m) = turn.kind else { return false }
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

enum ModelLocator {
    /// A model delivered later (e.g. from the phone) wins over the bundled copy.
    /// The 75 MB App Store limit for watch apps means the bundled copy is for
    /// development installs only. Whatever .gguf is present is used, so changing the
    /// model is a change to scripts/versions.env and project.yml, not to this file.
    static func modelURL() throws -> URL {
        let fm = FileManager.default
        let delivered = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KITT/Models", isDirectory: true)
        if let files = try? fm.contentsOfDirectory(at: delivered, includingPropertiesForKeys: nil),
           let model = files.filter({ $0.pathExtension == "gguf" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return model
        }
        if let bundled = Bundle.main.paths(forResourcesOfType: "gguf", inDirectory: nil).sorted().first {
            return URL(fileURLWithPath: bundled)
        }
        throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "No .gguf model in the app bundle or Application Support/KITT/Models"])
    }

    /// File name plus the checksum the build verified, saved with every model reply.
    static func modelID(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let bundled = url.path.hasPrefix(Bundle.main.bundlePath)
        let sha = bundled ? (Bundle.main.object(forInfoDictionaryKey: "KITTModelSHA256") as? String) : nil
        return sha.map { "\(name)@\($0.prefix(8))" } ?? name
    }

    static var describedModel: String {
        (try? modelURL()).map { modelID(for: $0) } ?? "no model installed"
    }
}
