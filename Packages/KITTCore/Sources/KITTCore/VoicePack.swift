import Foundation

/// One downloadable voice: every recorded guide reply for that voice, at Normal and Slower
/// speed, in a single file. It downloads, verifies and installs like the offline model
/// (`ModelStore`), and the watch reads a recording straight out of it by offset.
///
///     "KITTVOX1"       8 bytes
///     index length     UInt32, little-endian
///     index            JSON: {"clips": {"Guide-Heart-Normal-<sha256>": [offset, length], ...},
///                             "format": 1, "voice": "Heart"}
///     clips            the MP3s back to back; offsets count from the first clip byte
public struct VoicePack: Sendable {
    public static let magic = Array("KITTVOX1".utf8)
    public static let fileExtension = "kvoice"

    public struct Index: Codable, Equatable, Sendable {
        public var format: Int
        public var voice: String
        /// Recording name → [offset, length].
        public var clips: [String: [Int64]]
    }

    public enum PackError: Error, Equatable {
        case notAVoicePack
        case badIndex
        case clipOutOfRange(String)
    }

    public let url: URL
    public let index: Index
    private let clipsStart: UInt64

    /// Opens a pack and checks that every recording lies inside the file.
    public init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 12).map(Array.init), head.count == 12,
              Array(head[0..<8]) == Self.magic else { throw PackError.notAVoicePack }
        let length = UInt32(head[8]) | UInt32(head[9]) << 8 | UInt32(head[10]) << 16 | UInt32(head[11]) << 24
        guard length > 0, length < 16 << 20, let json = try handle.read(upToCount: Int(length)), json.count == Int(length),
              let index = try? JSONDecoder().decode(Index.self, from: json), index.format == 1
        else { throw PackError.badIndex }
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let start = 12 + Int64(length)
        for (name, range) in index.clips {
            guard range.count == 2, range[0] >= 0, range[1] > 0, start + range[0] + range[1] <= size else {
                throw PackError.clipOutOfRange(name)
            }
        }
        self.url = url
        self.index = index
        self.clipsStart = UInt64(start)
    }

    public var voice: String { index.voice }
    public var clipCount: Int { index.clips.count }

    /// The recording for this name, or nil if the pack has none.
    public func clip(named name: String) -> Data? {
        guard let range = index.clips[name], let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: clipsStart + UInt64(range[0]))) != nil,
              let data = try? handle.read(upToCount: Int(range[1])), data.count == Int(range[1]) else { return nil }
        return data
    }

    /// The recording for a spoken reply, if the pack has one.
    public func clip(for reply: SpokenReply, slower: Bool) -> Data? {
        clip(named: Self.clipName(voice: voice, slower: slower, transcript: reply.transcript))
    }

    /// The name a recording goes by: voice, speed, and the SHA-256 of the exact spoken text
    /// with its pauses (`SpokenReply.transcript`). Any change to the text gives a new name,
    /// so a stale recording is never played; the Apple voice reads that reply instead.
    public static func clipName(voice: String, slower: Bool, transcript: String) -> String {
        "Guide-\(voice)-\(slower ? "Slower" : "Normal")-" + ModelStore.sha256(of: Data(transcript.utf8))
    }

    /// Write a pack. Clips and index entries go in name order, and the index is written by
    /// hand rather than by JSONEncoder (whose key order differs between Apple platforms and
    /// Linux), so the same recordings make the same file, and the same SHA-256, anywhere.
    public static func write(voice: String, clips: [String: Data], to url: URL) throws {
        var entries: [String] = []
        var offset: Int64 = 0
        let names = clips.keys.sorted()
        for name in names {
            let length = Int64(clips[name]!.count)
            entries.append("\(try jsonString(name)):[\(offset),\(length)]")
            offset += length
        }
        let text = "{\"clips\":{\(entries.joined(separator: ","))},\"format\":1,\"voice\":\(try jsonString(voice))}"
        let json = Data(text.utf8)
        var out = Data(magic)
        let n = UInt32(json.count)
        out.append(contentsOf: [UInt8(n & 0xff), UInt8(n >> 8 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 24 & 0xff)])
        out.append(json)
        for name in names { out.append(clips[name]!) }
        try out.write(to: url, options: .atomic)
    }

    /// A JSON string literal. Clip and voice names are plain ASCII; anything else is refused
    /// rather than risk escaping that differs between platforms.
    private static func jsonString(_ text: String) throws -> String {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 && $0 != "\"" && $0 != "\\" })
        else { throw PackError.badIndex }
        return "\"" + text + "\""
    }
}
