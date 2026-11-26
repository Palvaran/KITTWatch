// Export watch narration from the same guide and conversation logic used at playback.
import Foundation
import KITTCore

let pack = try ContentPack.bundled()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

struct Line: Encodable {
    let text: String
    let pause: Double
}
var replies: [String: [Line]] = [:]
func capture(_ reply: SpokenReply) {
    replies[reply.transcript] = reply.segments.map { Line(text: $0.text, pause: $0.pauseAfter) }
}
func freshSession() throws -> KITTSession {
    let log = try EventLog(fileURL: directory.appendingPathComponent(UUID().uuidString), device: DeviceID("export"))
    return KITTSession(log: log, pack: pack)
}
func capture(_ outcome: TurnOutcome, in session: KITTSession) {
    guard case .answered(let message) = outcome else { fatalError("Expected a guide reply") }
    capture(SpeechText.reply(for: message, pack: pack, activeHazards: session.state.activeHazards))
}

for entry in pack.liveEntries {
    let session = try freshSession()
    capture(try session.ask(entryID: entry.id), in: session)
    if entry.hazard != nil {
        var warning = AssistantMessage(text: entry.shortAnswer + "\n" + KITTSession.precautionNote,
                                       origin: .guide, citations: [entry.citation])
        warning.suggestedHazard = entry.id
        capture(SpeechText.reply(for: warning, pack: pack))
        warning.suggestions = entry.related.filter { pack.entry($0)?.review.status != .retired }
        capture(SpeechText.reply(for: warning, pack: pack))
    }
    if entry.calculator != nil {
        for people in 1...5 {
            for days in [nil, 3, 7] as [Int?] {
                let plan = try freshSession()
                _ = try plan.setFact(.people, Double(people))
                if let days { _ = try plan.setFact(.planDays, Double(days)) }
                capture(try plan.ask(entryID: entry.id), in: plan)
            }
        }
    } else {
        for note in [nil] + entry.notes.map(Optional.some) {
            var text = entry.shortAnswer
            if let note {
                text = note.lead == true ? note.note + "\n" + text : text + "\n• " + note.note
            }
            capture(SpeechText.reply(for: AssistantMessage(text: text, origin: .guide, citations: [entry.citation]), pack: pack))
        }
    }
}
for turns in [
    ["The generator is in the garage.", "Not sure", "Not in use"],
    ["The generator is in the garage.", "This applies to us"],
    ["The generator is in the basement.", "Yes, it is running.", "What if I leave the door open?"],
    ["Change our water plan to seven days."],
    ["Our tap water smells like gasoline.", "Would boiling help?"],
    ["The city sent a water alert. Can the dog drink from the tap?", "Not sure", "Do not use", "Can we shower?", "They've lifted the boil notice."],
    ["We got a water notice. Can I brush my teeth?", "Boil water", "The boil notice was lifted."],
    ["We got a water notice. Can I wash the dishes?", "Boil water"],
    ["We got a water notice. Can we use this for baby formula?", "Boil water"],
    ["We got a water notice. Can I brush my teeth?", "Do not drink"]
] {
    let session = try freshSession()
    for turn in turns { capture(try session.send(turn), in: session) }
}
for installed in [true, false] {
    let session = try freshSession()
    session.modelAvailable = installed
    capture(try session.send("Astronomy"), in: session)
}
capture(SpokenReply(segments: [SpokenSegment(SpeechText.voiceSample)]))
FileHandle.standardOutput.write(try JSONEncoder().encode(replies))
