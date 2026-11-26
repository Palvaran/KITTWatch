import Foundation
import KITTCore
import KITTEngine

// kitt: run the watch's pipeline and model off the wrist.
//
//   kitt ask   --model M [--people N] [--auto-model] "question" ["follow-up" ...]
//   kitt raw   --model M [--system S] --user U [--max N]
//   kitt eval  --model M --scenarios Eval/scenarios.json [--out DIR]
//   kitt bench --model M
//
// Without --model, `ask` and `eval` still run everything that does not need the model.

let usage = """
usage:
  kitt ask   [--model FILE] [--pack FILE] [--people N] [--days N] [--speech] [--auto-model] [--policy groundedFollowUps|onRequest] "question" ...
  kitt raw    --model FILE [--system TEXT] --user TEXT [--max N] [--sentences N]
  kitt eval  [--model FILE] [--pack FILE] --scenarios FILE [--out DIR] [--only FAMILY]
  kitt trial  QUESTIONS.txt --out TRIAL.json [--name NAME] [--people N] [--force]
  kitt bench  --model FILE [--runs N]
  kitt search [--pack FILE] "question" ...
"""

var raw = Array(CommandLine.arguments.dropFirst())
guard let command = raw.first else { print(usage); exit(0) }
raw.removeFirst()
let args = Arguments(raw, flags: ["auto-model", "verbose", "json", "speech", "force"])

func loadEngine(_ args: Arguments, required: Bool) -> LlamaEngine? {
    guard let path = args.string("model") else {
        if required { fail("--model FILE is required") }
        return nil
    }
    let url = expand(path)
    var config = LlamaEngine.Config()
    if let t = args.int("threads") { config.threads = Int32(t) }
    if let c = args.int("context") { config.contextTokens = UInt32(c) }
    do {
        return try LlamaEngine(modelURL: url, modelID: url.deletingPathExtension().lastPathComponent, config: config)
    } catch {
        fail("\(error)")
    }
}

func loadPack(_ args: Arguments) -> ContentPack {
    do {
        if let p = args.string("pack") { return try ContentPack.load(from: expand(p)) }
        return try ContentPack.bundled()
    } catch {
        fail("could not load guide pack: \(error)")
    }
}

switch command {
case "ask": runAsk(args)
case "raw": runRaw(args)
case "eval": runEval(args)
case "trial": runTrial(args)
case "bench": runBench(args)
case "search":
    // Show how local search ranks a question (for tuning keywords in the pack).
    let search = GuideSearch(pack: loadPack(args))
    for q in args.positional {
        print("> \(q)")
        switch search.retrieve(q) {
        case .confident(let c): print("  confident: \(c.entry.id)")
        case .ambiguous: print("  ambiguous")
        case .none: print("  none")
        }
        for c in search.rank(q).prefix(4) { print(String(format: "  %5.2f  cov %.2f  %@", c.score, c.coverage, c.entry.id)) }
        let hazards = search.hazardsRaised(by: q).map(\.id)
        if !hazards.isEmpty { print("  raises: " + hazards.joined(separator: ", ")) }
    }
case "help", "--help", "-h": print(usage)
default: fail("unknown command \(command)\n\(usage)")
}
