import Foundation
import KITTCore
import KITTEngine

/// kitt eval: run the scenario suite against each build and write the comparison the
/// brief's milestone 4 asks for (model alone, model with retrieval, KITT pipeline).
func runEval(_ args: Arguments) {
    guard let scenariosPath = args.string("scenarios") else { fail("--scenarios FILE is required") }
    let pack = loadPack(args)
    let problems = pack.problems()
    if !problems.isEmpty { fail("guide pack has problems:\n  " + problems.joined(separator: "\n  ")) }
    let suite: EvalSuite
    do { suite = try JSONDecoder().decode(EvalSuite.self, from: Data(contentsOf: expand(scenariosPath))) }
    catch { fail("could not read scenarios: \(error)") }

    let engine = loadEngine(args, required: false)
    let builds: [EvalBuild]
    if let list = args.string("builds") {
        builds = list.split(separator: ",").compactMap { EvalBuild(rawValue: String($0)) }
    } else {
        builds = engine == nil ? [.pipeline] : EvalBuild.allCases
    }

    var reports: [EvalReport] = []
    for build in builds {
        do {
            reports.append(try EvalRunner.run(build, suite: suite, pack: pack, generator: engine, only: args.string("only")) { line in
                if args.has("verbose") { FileHandle.standardError.write(Data((line + "\n").utf8)) }
            })
        } catch {
            fail("\(build.rawValue): \(error)")
        }
    }

    let markdown = renderMarkdown(reports, modelName: engine?.modelID)
    if let out = args.string("out") {
        let dir = expand(out)
        let name = (engine?.modelID ?? "no-model")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try markdown.write(to: dir.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(reports).write(to: dir.appendingPathComponent("\(name).json"))
            print("wrote \(dir.path)/\(name).md and .json")
        } catch {
            fail("\(error)")
        }
    }
    print(summaryTable(reports))
    if args.has("verbose") || args.string("out") == nil { print(failures(reports)) }
}

private func fraction(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : "\(a)/\(b)" }

func summaryTable(_ reports: [EvalReport]) -> String {
    var lines = ["| Build | Split | Right entry or \"not covered\" | Right entry offered as a button instead | Answer checks passed | Critical failures | of which: warning not shown | Wrong hazard flags | Replies with numbers not in guide |",
                 "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for r in reports {
        for split in ["dev", "heldout"] {
            let t = r.tally(split: split)
            guard t.routingJudged + t.contentJudged > 0 else { continue }
            let judged = t.routingJudged > 0
            let flags = t.flagsJudged > 0 ? "\(t.wrongFlags) of \(t.flagsJudged)" : "–"
            lines.append("| \(r.build.rawValue) | \(split) | \(fraction(t.routingCorrect, t.routingJudged)) | \(judged ? String(t.routingOffered) : "–") | \(fraction(t.contentCorrect, t.contentJudged)) | \(t.criticalFailures) | \(judged ? String(t.criticalNotShown) : "–") | \(flags) | \(t.repliesWithUnsupportedNumbers) |")
        }
    }
    return lines.joined(separator: "\n")
}

func failures(_ reports: [EvalReport]) -> String {
    var out = ""
    for r in reports {
        for s in r.results {
            for t in s.turns where !t.problems.isEmpty {
                out += "\n[\(r.build.rawValue)] \(s.family)/\(s.scenario)\(s.critical ? " (critical)" : "")\n  > \(t.say)\n  < \(t.reply.replacingOccurrences(of: "\n", with: "\n    "))\n  ✗ \(t.problems.joined(separator: "; "))\n"
            }
        }
    }
    return out
}

func renderMarkdown(_ reports: [EvalReport], modelName: String?) -> String {
    var out = "# KITT evaluation: \(modelName ?? "no model")\n\n"
    out += "Guide pack: \(reports.first?.packVersion ?? "?"). Greedy decoding, so a rerun gives the same replies.\n"
    out += "Answer checks are phrase lists from Eval/scenarios.json. They catch plain errors; read the transcripts before trusting a pass.\nA critical failure is any turn in a critical family that failed a check or did not show the expected entry outright.\n\n"
    out += summaryTable(reports) + "\n"
    for r in reports {
        out += "\n## \(r.build.rawValue)\n"
        for s in r.results {
            out += "\n**\(s.family) / \(s.scenario)**\(s.critical ? " (critical)" : "") · \(s.split)\n\n"
            for t in s.turns {
                let mark = t.problems.isEmpty ? "✓" : "✗"
                out += "- **You:** \(t.say)\n"
                out += "  **\(t.origin)\(t.citations.isEmpty ? "" : " [" + t.citations.joined(separator: ", ") + "]"):** \(t.reply.replacingOccurrences(of: "\n", with: " / "))\n"
                out += "  \(mark)\(t.problems.isEmpty ? "" : " " + t.problems.joined(separator: "; "))"
                if !t.unsupportedNumbers.isEmpty { out += " · numbers not in guide: " + t.unsupportedNumbers.joined(separator: ", ") }
                out += "\n"
            }
        }
    }
    return out
}
