import Foundation
import KITTCore
import KITTEngine

func statsLine(_ s: GenerationStats) -> String {
    let ttft = s.timeToFirstTokenMilliseconds.map { String(format: "%.0f ms", $0) } ?? "-"
    return String(format: "prompt %d tok (%d reused), first word %@, %d tok at %.1f tok/s, stop: %@",
                  s.promptTokens, s.reusedTokens, ttft, s.generatedTokens, s.tokensPerSecond, s.stop.rawValue)
}

func temporaryLog(device: String = "cli") -> EventLog {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-cli-\(UUID().uuidString).jsonl")
    do { return try EventLog(fileURL: url, device: DeviceID(device)) } catch { fail("\(error)") }
}

func describe(_ m: AssistantMessage, pack: ContentPack) -> String {
    var head: String
    switch m.origin {
    case .guide: head = "GUIDE"
    case .app: head = "KITT"
    case .model: head = m.citations.isEmpty ? "MODEL (no guide text)" : "MODEL (from guide passage)"
    }
    if !m.citations.isEmpty { head += " [" + m.citations.joined(separator: ", ") + "]" }
    var out = head + "\n" + m.text
    if !m.unsupportedNumbers.isEmpty { out += "\n! numbers not in the guide: " + m.unsupportedNumbers.joined(separator: ", ") }
    if !m.suggestions.isEmpty {
        out += "\n  buttons: " + m.suggestions.map { pack.entry($0)?.title ?? $0 }.joined(separator: " | ")
    }
    if m.offersModel { out += "\n  button: Ask the model anyway (unverified)" }
    if let h = m.suggestedHazard { out += "\n  button: This applies to us (flags \(h))" }
    if m.asksHazardQuestion {
        out += "\n  buttons: Not in use (\"\(KITTSession.notInUseAnswer)\") | Not sure (\"\(KITTSession.notSureAnswer)\")"
    }
    if m.noticeQuestion != nil { out += "\n  buttons: " + WaterNotice.answers.joined(separator: " | ") }
    return out
}

func runAsk(_ args: Arguments) {
    let pack = loadPack(args)
    let engine = loadEngine(args, required: false)
    let session = KITTSession(log: temporaryLog(), pack: pack)
    if let p = args.string("policy"), let policy = ModelPolicy(rawValue: p) { session.modelPolicy = policy }
    do {
        if let n = args.int("people") { try session.setFact(.people, Double(n)) }
        if let n = args.int("days") { try session.setFact(.planDays, Double(n)) }
        // --speech: also print what the watch reads aloud for each reply.
        func spoken(_ m: AssistantMessage) {
            // "(tap)" marks the wrist tap that starts an urgent reply; [pause] the silences.
            if args.has("speech") { print("  spoken: " + SpeechText.reply(for: m, pack: pack, activeHazards: session.state.activeHazards).transcript) }
        }
        if let engine { try engine.prewarm(PromptBuilder.grounded(question: "", passages: [])) }

        func runModel(_ request: ModelRequest) throws {
            guard let engine else { print("(model needed; pass --model to run it)\n"); return }
            if args.has("verbose") { for t in request.prompt.turns { print("    [\(t.role.rawValue)] \(t.content)") } }
            var text = ""
            let stats = try engine.generate(request.prompt) { text += $0 }
            let saved = try session.recordModelReply(text, for: request, modelID: engine.modelID, interrupted: stats.stop == .cancelled)
            print(describe(saved, pack: pack))
            spoken(saved)
            if saved.text != text.trimmingCharacters(in: .whitespacesAndNewlines) { print("  (model said: \(text.trimmingCharacters(in: .whitespacesAndNewlines)))") }
            print("  " + statsLine(stats) + "\n")
        }

        let questions = args.positional
        guard !questions.isEmpty else { fail("give at least one question") }
        for q in questions {
            print("> \(q)")
            switch try session.send(q) {
            case .answered(let m):
                print(describe(m, pack: pack))
                spoken(m)
                print("")
                if m.offersModel, args.has("auto-model"), let request = session.modelRequestForUnansweredQuestion() {
                    print("> [Ask the model anyway]")
                    try runModel(request)
                }
            case .needsModel(let request):
                try runModel(request)
            }
        }
        let h = session.household
        print("household: " + [h.people?.label, h.planDays.map { "plan \($0.label)" }, h.storedWater.map { "\($0.label) stored" }]
            .compactMap { $0 }.joined(separator: ", "))
        let hazards = session.state.activeHazards
        print("flagged hazards: " + (hazards.isEmpty ? "none" : hazards.joined(separator: ", ")))
        let s = session.state
        if let n = s.waterNotice { print("water notice: " + n.answer) } else if s.waterNoticeUnsure { print("water notice: not sure which") }
        let answers = session.state.hazardAnswers.sorted { $0.key < $1.key }
        if !answers.isEmpty {
            print("answered, not flagged: " + answers.map { "\($0.key) (\($0.value.title.lowercased()))" }.joined(separator: ", "))
        }
    } catch {
        fail("\(error)")
    }
}

func runRaw(_ args: Arguments) {
    guard let engine = loadEngine(args, required: true) else { return }
    guard let user = args.string("user") else { fail("--user TEXT is required") }
    var turns: [ChatTurn] = []
    if let s = args.string("system") { turns.append(ChatTurn(.system, s)) }
    turns.append(ChatTurn(.user, user))
    let prompt = ModelPrompt(turns: turns, maxNewTokens: args.int("max") ?? 96, maxSentences: args.int("sentences") ?? 0,
                             deterministic: !args.has("sample"))
    do {
        var text = ""
        let stats = try engine.generate(prompt) { text += $0 }
        print(text.trimmingCharacters(in: .whitespacesAndNewlines))
        print("  " + statsLine(stats))
    } catch {
        fail("\(error)")
    }
}

func runBench(_ args: Arguments) {
    guard let engine = loadEngine(args, required: true) else { return }
    let runs = args.int("runs") ?? 3
    let passage = "Store at least 1 US gallon of water per person per day, for several days, for drinking and sanitation. Children, nursing mothers, sick people, and hot weather need more."
    let questions = ["Why per person?", "Does that include washing?", "What about very hot weather?"]
    print(String(format: "model load: %.0f ms", engine.loadMilliseconds))
    do {
        let warm = DispatchTime.now()
        try engine.prewarm(PromptBuilder.grounded(question: "", passages: []))
        print(String(format: "prewarm (system text): %.0f ms", Double(DispatchTime.now().uptimeNanoseconds - warm.uptimeNanoseconds) / 1e6))
        for i in 0..<runs {
            let prompt = PromptBuilder.grounded(question: questions[i % questions.count], passages: [passage])
            let stats = try engine.generate(prompt) { _ in }
            print(String(format: "run %d: %@ | prefill %.0f tok/s", i + 1, statsLine(stats), stats.prefillTokensPerSecond))
        }
    } catch {
        fail("\(error)")
    }
}
