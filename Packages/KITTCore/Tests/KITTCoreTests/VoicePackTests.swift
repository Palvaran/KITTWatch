import XCTest
@testable import KITTCore

final class VoicePackTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-voice-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testClipsComeBackByteForByte() throws {
        let url = dir.appendingPathComponent("heart.kvoice")
        let clips = [
            "Guide-Heart-Normal-aa": Data("first recording".utf8),
            "Guide-Heart-Slower-aa": Data(repeating: 0xFF, count: 70_000),
            "Guide-Heart-Normal-bb": Data([0, 1, 2, 3]),
        ]
        try VoicePack.write(voice: "Heart", clips: clips, to: url)
        let pack = try VoicePack(contentsOf: url)
        XCTAssertEqual(pack.voice, "Heart")
        XCTAssertEqual(pack.clipCount, 3)
        for (name, data) in clips { XCTAssertEqual(pack.clip(named: name), data, name) }
        XCTAssertNil(pack.clip(named: "Guide-Heart-Normal-cc"))
    }

    func testTheSameRecordingsMakeTheSameFile() throws {
        let clips = ["b": Data("2".utf8), "a": Data("1".utf8), "c": Data("3".utf8)]
        let one = dir.appendingPathComponent("1.kvoice"), two = dir.appendingPathComponent("2.kvoice")
        try VoicePack.write(voice: "Michael", clips: clips, to: one)
        try VoicePack.write(voice: "Michael", clips: clips, to: two)
        XCTAssertEqual(try Data(contentsOf: one), try Data(contentsOf: two))
    }

    /// The exact bytes, so a pack built on the Mac matches one built on Linux.
    func testThePackLayoutIsFixed() throws {
        let url = dir.appendingPathComponent("tiny.kvoice")
        try VoicePack.write(voice: "Heart", clips: ["b-1": Data("BB".utf8), "a-10": Data("A".utf8), "a-9": Data("9".utf8)], to: url)
        let index = #"{"clips":{"a-10":[0,1],"a-9":[1,1],"b-1":[2,2]},"format":1,"voice":"Heart"}"#
        var expected = Data("KITTVOX1".utf8)
        expected.append(contentsOf: [UInt8(index.utf8.count), 0, 0, 0])
        expected.append(Data(index.utf8))
        expected.append(Data("A9BB".utf8))
        XCTAssertEqual(try Data(contentsOf: url), expected)
        XCTAssertThrowsError(try VoicePack.write(voice: "He\"art", clips: ["a": Data([1])], to: url))
    }

    func testAReplyFindsItsRecordingAtTheChosenSpeed() throws {
        let reply = SpokenReply(segments: [SpokenSegment("Boil water for one minute.", pauseAfter: 0.4),
                                           SpokenSegment("Let it cool.")])
        let normal = VoicePack.clipName(voice: "Heart", slower: false, transcript: reply.transcript)
        let slower = VoicePack.clipName(voice: "Heart", slower: true, transcript: reply.transcript)
        XCTAssertTrue(normal.hasPrefix("Guide-Heart-Normal-"))
        XCTAssertEqual(normal.count, "Guide-Heart-Normal-".count + 64)
        let url = dir.appendingPathComponent("heart.kvoice")
        try VoicePack.write(voice: "Heart", clips: [normal: Data("N".utf8), slower: Data("S".utf8)], to: url)
        let pack = try VoicePack(contentsOf: url)
        XCTAssertEqual(pack.clip(for: reply, slower: false), Data("N".utf8))
        XCTAssertEqual(pack.clip(for: reply, slower: true), Data("S".utf8))
        // Changed wording means a new name, so an old recording is never played for new text.
        let edited = SpokenReply(segments: [SpokenSegment("Boil water for three minutes.", pauseAfter: 0.4),
                                            SpokenSegment("Let it cool.")])
        XCTAssertNil(pack.clip(for: edited, slower: false))
    }

    /// The names match the ones Codex's narration export used (SHA-256 of the transcript).
    func testClipNameIsTheSHA256OfTheTranscript() {
        XCTAssertEqual(VoicePack.clipName(voice: "Michael", slower: true, transcript: "abc"),
                       "Guide-Michael-Slower-ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testOtherFilesAreRefused() throws {
        let url = dir.appendingPathComponent("model.gguf")
        try Data("GGUF and then some model bytes".utf8).write(to: url)
        XCTAssertThrowsError(try VoicePack(contentsOf: url)) { XCTAssertEqual($0 as? VoicePack.PackError, .notAVoicePack) }
        let empty = dir.appendingPathComponent("empty.kvoice")
        try Data().write(to: empty)
        XCTAssertThrowsError(try VoicePack(contentsOf: empty))
    }

    func testACutShortPackIsRefused() throws {
        let url = dir.appendingPathComponent("heart.kvoice")
        try VoicePack.write(voice: "Heart", clips: ["a": Data(repeating: 1, count: 1000)], to: url)
        let whole = try Data(contentsOf: url)
        try whole.prefix(whole.count - 10).write(to: url)
        XCTAssertThrowsError(try VoicePack(contentsOf: url)) { XCTAssertEqual($0 as? VoicePack.PackError, .clipOutOfRange("a")) }
    }

    func testEachDownloadReadsItsOwnInfoPlistKeys() {
        let sha = String(repeating: "ab", count: 32)
        let info: [String: Any] = [
            "KITTModelFile": "model.gguf", "KITTModelSHA256": sha, "KITTModelBytes": 92,
            "KITTModelURL": "https://example.com/model.gguf",
            "KITTVoiceHeartFile": "kitt-voice-heart-v1.kvoice", "KITTVoiceHeartSHA256": sha,
            "KITTVoiceHeartBytes": "19000000", "KITTVoiceHeartURL": "https://example.com/heart.kvoice",
        ]
        XCTAssertEqual(ModelManifest(infoDictionary: info)?.fileName, "model.gguf")
        let heart = ModelManifest(infoDictionary: info, prefix: "KITTVoiceHeart")
        XCTAssertEqual(heart?.fileName, "kitt-voice-heart-v1.kvoice")
        XCTAssertEqual(heart?.bytes, 19_000_000)
        XCTAssertNil(ModelManifest(infoDictionary: info, prefix: "KITTVoiceMichael"))
    }

    /// A voice pack installs through the same verified store as the model.
    func testAPackInstallsAndOpensFromTheStore() throws {
        let built = dir.appendingPathComponent("built.kvoice")
        try VoicePack.write(voice: "Heart", clips: ["x": Data("hello".utf8)], to: built)
        let bytes = Int64(try Data(contentsOf: built).count)
        let manifest = ModelManifest(fileName: "kitt-voice-heart-v1.kvoice", sha256: try ModelStore.sha256(of: built),
                                     bytes: bytes, url: URL(string: "https://example.com/heart.kvoice")!)
        let store = ModelStore(directory: dir.appendingPathComponent("Voices/Heart", isDirectory: true), manifest: manifest)
        _ = try store.install(downloadedFile: built)
        let installed = try XCTUnwrap(store.installedURL)
        XCTAssertEqual(try VoicePack(contentsOf: installed).clip(named: "x"), Data("hello".utf8))
    }
}
