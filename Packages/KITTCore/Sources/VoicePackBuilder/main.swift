// Builds one downloadable voice pack from the guide recordings.
//
//   voice-pack --voice Heart --from Voices/narration --out Voices/dist/kitt-voice-heart-v1.kvoice
//              [--lines lines.json]
//
// --lines takes the output of guide-voice-lines. Recordings for text the guide no longer
// says are left out, and replies with no recording are counted, so the report shows what
// the Apple voice will read instead.
import Foundation
import KITTCore

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var options: [String: String] = [:]
var args = CommandLine.arguments.dropFirst()
while let key = args.popFirst() {
    guard key.hasPrefix("--"), let value = args.popFirst() else {
        fail("usage: voice-pack --voice NAME --from DIR --out FILE [--lines lines.json]")
    }
    options[String(key.dropFirst(2))] = value
}
guard let voice = options["voice"], let from = options["from"], let out = options["out"] else {
    fail("usage: voice-pack --voice NAME --from DIR --out FILE [--lines lines.json]")
}

let fm = FileManager.default
let source = URL(fileURLWithPath: from, isDirectory: true)
let names = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
let pattern = try NSRegularExpression(pattern: "^Guide-\(NSRegularExpression.escapedPattern(for: voice))-(Normal|Slower)-[0-9a-f]{64}\\.mp3$")
let recordings = names.filter { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.sorted()
guard !recordings.isEmpty else { fail("No Guide-\(voice)-*.mp3 recordings in \(source.path)") }

var transcripts: [String]?
var wanted: Set<String>?
if let lines = options["lines"] {
    guard let data = fm.contents(atPath: lines),
          let replies = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { fail("Could not read \(lines)") }
    transcripts = Array(replies.keys)
    wanted = Set(replies.keys.flatMap { transcript in
        [false, true].map { VoicePack.clipName(voice: voice, slower: $0, transcript: transcript) }
    })
}

var clips: [String: Data] = [:]
var stale: [String] = []
for file in recordings {
    let name = String(file.dropLast(4))
    if let wanted, !wanted.contains(name) { stale.append(file); continue }
    guard let data = fm.contents(atPath: source.appendingPathComponent(file).path), !data.isEmpty else {
        fail("Could not read \(file)")
    }
    clips[name] = data
}
guard !clips.isEmpty else { fail("Every \(voice) recording is for text the guide no longer says.") }

let output = URL(fileURLWithPath: out)
try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
try VoicePack.write(voice: voice, clips: clips, to: output)

// Read it back the way the watch will before reporting it.
let pack = try VoicePack(contentsOf: output)
for (name, data) in clips where pack.clip(named: name) != data { fail("\(name) did not read back intact") }
let bytes = ((try fm.attributesOfItem(atPath: output.path))[.size] as? NSNumber)?.int64Value ?? 0
let sha = try ModelStore.sha256(of: output)

var report = ["\(output.lastPathComponent): \(pack.clipCount) recordings, \(String(format: "%.1f", Double(bytes) / 1_000_000)) MB"]
if let transcripts {
    func recorded(_ slower: Bool) -> Int {
        transcripts.filter { clips[VoicePack.clipName(voice: voice, slower: slower, transcript: $0)] != nil }.count
    }
    report.append("Guide replies recorded: \(recorded(false)) of \(transcripts.count) at Normal, \(recorded(true)) at Slower. The Apple voice reads the rest.")
}
if !stale.isEmpty {
    report.append("Left out \(stale.count) recording(s) for text the guide no longer says:")
    report += stale.prefix(10).map { "  " + $0 }
}
FileHandle.standardError.write(Data((report.joined(separator: "\n") + "\n").utf8))
// stdout: the values versions.env needs, one per line.
print("FILE=\(output.lastPathComponent)")
print("SHA256=\(sha)")
print("BYTES=\(bytes)")
