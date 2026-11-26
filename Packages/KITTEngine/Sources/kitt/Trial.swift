import Foundation
import KITTCore

/// kitt trial: turn a blind trial's plain-text questions into a scenario file that
/// `kitt eval` runs. The person writing the questions shouldn't have read the guide, and
/// the file stays away from whoever edits the guide's phrasings until both builds are scored.
///
/// Text format: one question per line. A blank line starts a new conversation, so
/// consecutive lines are follow-ups in one conversation. Lines starting with # are ignored.
///
///     The power went out last night. Is the milk okay?
///     What about the cheese?
///
///     The city says boil the water. Can I brush my teeth with it?
///
/// The scenarios have no expectations yet; label them afterwards (see Eval/BLIND-TRIAL.md).
func runTrial(_ args: Arguments) {
    guard let input = args.positional.first else { fail("usage: kitt trial QUESTIONS.txt --out TRIAL.json [--name NAME] [--people N]") }
    guard let out = args.string("out") else { fail("--out TRIAL.json is required") }
    let text: String
    do { text = try String(contentsOf: expand(input), encoding: .utf8) } catch { fail("could not read \(input): \(error)") }

    let suite = EvalSuite.blindTrial(from: text, name: args.string("name") ?? "blind", people: args.int("people"))
    let turns = suite.families.flatMap(\.scenarios).reduce(0) { $0 + $1.turns.count }
    guard turns > 0 else { fail("no questions in \(input)") }
    let destination = expand(out)
    if FileManager.default.fileExists(atPath: destination.path), !args.has("force") {
        fail("\(destination.path) exists; it may hold labels. Pass --force to overwrite it.")
    }
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(suite).write(to: destination)
    } catch {
        fail("\(error)")
    }
    print("wrote \(destination.path): \(suite.families[0].scenarios.count) conversations, \(turns) questions")
}
