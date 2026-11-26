import XCTest
@testable import KITTCore

final class OfflineModelTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitt-model-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stand-in model: some bytes and the manifest that describes them.
    func model(_ name: String, _ text: String) throws -> (manifest: ModelManifest, download: URL) {
        let data = Data(text.utf8)
        let download = dir.appendingPathComponent("download-\(UUID()).tmp")
        try data.write(to: download)
        let manifest = ModelManifest(fileName: name, sha256: try ModelStore.sha256(of: download),
                                     bytes: Int64(data.count), url: URL(string: "https://example.com/\(name)")!)
        return (manifest, download)
    }

    func store(_ manifest: ModelManifest) -> ModelStore {
        ModelStore(directory: dir.appendingPathComponent("Models", isDirectory: true), manifest: manifest)
    }

    func testSHA256KnownAnswers() throws {
        func digest(_ data: Data) throws -> String {
            let url = dir.appendingPathComponent("\(UUID())")
            try data.write(to: url)
            return try ModelStore.sha256(of: url)
        }
        XCTAssertEqual(try digest(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(try digest(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try digest(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        // Two 1 MB reads plus a remainder, so the boundary between reads is crossed.
        XCTAssertEqual(try digest(Data(repeating: UInt8(ascii: "a"), count: 1_000_000)),
                       "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// A large real file, against the system's sha256sum when it is available.
    func testSHA256MatchesSha256sumOnALargeFile() throws {
        let path = ProcessInfo.processInfo.environment["KITT_SHA_CHECK_FILE"] ?? ""
        let expected = ProcessInfo.processInfo.environment["KITT_SHA_CHECK_DIGEST"] ?? ""
        guard !path.isEmpty, !expected.isEmpty else { throw XCTSkip("set KITT_SHA_CHECK_FILE and KITT_SHA_CHECK_DIGEST") }
        XCTAssertEqual(try ModelStore.sha256(of: URL(fileURLWithPath: path)), expected)
    }

    func testManifestFromInfoPlistValues() {
        let info: [String: Any] = [
            "KITTModelFile": "SmolLM2-135M-Instruct-Q4_0.gguf",
            "KITTModelSHA256": "BCC3AF2849AD6095AF57E9B5CD43775256EFDC66E306ACB529172F92D0C04B03",
            "KITTModelBytes": NSNumber(value: 91_893_088),
            "KITTModelURL": "https://huggingface.co/x/y/resolve/rev/SmolLM2-135M-Instruct-Q4_0.gguf",
        ]
        let manifest = ModelManifest(infoDictionary: info)
        XCTAssertEqual(manifest?.bytes, 91_893_088)
        XCTAssertEqual(manifest?.id, "SmolLM2-135M-Instruct-Q4_0@bcc3af28", "checksum is stored lowercase")
        XCTAssertEqual(manifest?.sizeLabel, "92 MB")
        var missing = info
        missing["KITTModelURL"] = nil
        XCTAssertNil(ModelManifest(infoDictionary: missing), "a build without the manifest offers no download")
        var short = info
        short["KITTModelSHA256"] = "bcc3"
        XCTAssertNil(ModelManifest(infoDictionary: short))
    }

    func testAVerifiedDownloadIsInstalled() throws {
        let (manifest, download) = try model("small.gguf", "weights v1")
        let store = store(manifest)
        XCTAssertNil(store.installed)
        let installed = try store.install(downloadedFile: download)
        XCTAssertTrue(installed.matches(manifest))
        XCTAssertEqual(store.installed, installed)
        XCTAssertEqual(store.installedURL?.lastPathComponent, "small.gguf")
        XCTAssertEqual(try String(contentsOf: store.installedURL!, encoding: .utf8), "weights v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path), "the download was moved, not copied")
        XCTAssertFalse(store.hasPendingFile)
        XCTAssertFalse(store.hasUpdate)
    }

    func testABadDownloadIsDeletedAndNothingIsInstalled() throws {
        let (manifest, _) = try model("small.gguf", "weights v1")
        let store = store(manifest)

        let corrupt = dir.appendingPathComponent("corrupt.tmp")
        try Data("weights v2".utf8).write(to: corrupt)   // same size, different bytes
        XCTAssertThrowsError(try store.install(downloadedFile: corrupt)) { error in
            guard case ModelInstallError.checksumMismatch = error else { return XCTFail("\(error)") }
        }
        let truncated = dir.appendingPathComponent("truncated.tmp")
        try Data("weights".utf8).write(to: truncated)
        XCTAssertThrowsError(try store.install(downloadedFile: truncated)) { error in
            XCTAssertEqual(error as? ModelInstallError, .wrongSize(expected: 10, actual: 7))
        }
        XCTAssertNil(store.installed)
        XCTAssertFalse(store.hasPendingFile, "a failed download does not linger")
    }

    /// An upgrade keeps the working model until its replacement passes verification.
    func testAnUpgradeKeepsTheWorkingModelUntilTheNewOneVerifies() throws {
        let (old, oldDownload) = try model("small-v1.gguf", "weights v1")
        try store(old).install(downloadedFile: oldDownload)

        let (new, newDownload) = try model("small-v2.gguf", "weights v2, larger")
        let upgraded = store(new)
        XCTAssertTrue(upgraded.hasUpdate, "an older verified model is installed")
        XCTAssertEqual(upgraded.installedURL?.lastPathComponent, "small-v1.gguf", "and still used meanwhile")

        let bad = dir.appendingPathComponent("bad.tmp")
        try Data("weights v2, LARGER".utf8).write(to: bad)
        XCTAssertThrowsError(try upgraded.install(downloadedFile: bad))
        XCTAssertEqual(upgraded.installed?.fileName, "small-v1.gguf", "a failed upgrade leaves the old model working")

        try upgraded.install(downloadedFile: newDownload)
        XCTAssertEqual(upgraded.installed?.fileName, "small-v2.gguf")
        XCTAssertFalse(upgraded.hasUpdate)
        let files = try FileManager.default.contentsOfDirectory(atPath: upgraded.directory.path).filter { $0.hasSuffix(".gguf") }
        XCTAssertEqual(files, ["small-v2.gguf"], "the old model is removed once the new one is in place")
    }

    /// Same file name, new contents: replaced in place, and only after verification.
    func testAReplacementWithTheSameNameIsSwappedInPlace() throws {
        let (old, oldDownload) = try model("model.gguf", "aaaa")
        try store(old).install(downloadedFile: oldDownload)
        let (new, newDownload) = try model("model.gguf", "bbbb")
        let upgraded = store(new)
        XCTAssertTrue(upgraded.hasUpdate)
        try upgraded.install(downloadedFile: newDownload)
        XCTAssertEqual(try String(contentsOf: upgraded.installedURL!, encoding: .utf8), "bbbb")
        XCTAssertTrue(upgraded.installed!.matches(new))
    }

    /// KITT was stopped after the download arrived but before it was checked.
    func testAPendingDownloadIsVerifiedOnTheNextLaunch() throws {
        let (manifest, download) = try model("small.gguf", "weights v1")
        let store = store(manifest)
        try FileManager.default.createDirectory(at: store.pendingURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: download, to: store.pendingURL)
        XCTAssertNil(store.installed)
        XCTAssertEqual(try store.finishPendingInstall()?.fileName, "small.gguf")
        XCTAssertNotNil(store.installed)
        XCTAssertNil(try store.finishPendingInstall(), "nothing left to do")
    }

    /// A model file whose size changed since it was verified is not trusted.
    func testATruncatedModelIsNotTreatedAsInstalled() throws {
        let (manifest, download) = try model("small.gguf", "weights v1")
        let store = store(manifest)
        try store.install(downloadedFile: download)
        try Data("weights".utf8).write(to: store.installedURL!)
        XCTAssertNil(store.installed)
    }

    func testDeleteRemovesTheModelAndAnyPartialDownload() throws {
        let (manifest, download) = try model("small.gguf", "weights v1")
        let store = store(manifest)
        try store.install(downloadedFile: download)
        store.saveResumeData(Data("resume".utf8))
        XCTAssertTrue(store.hasResumeData)
        try store.delete()
        XCTAssertNil(store.installed)
        XCTAssertFalse(store.hasResumeData)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(left, [], "nothing of the model is left")
    }

    func testResumeDataIsHandedOutOnce() throws {
        let (manifest, _) = try model("small.gguf", "weights v1")
        let store = store(manifest)
        XCTAssertNil(store.takeResumeData())
        store.saveResumeData(Data("resume".utf8))
        XCTAssertEqual(store.takeResumeData(), Data("resume".utf8))
        XCTAssertNil(store.takeResumeData())
        store.saveResumeData(Data("resume".utf8))
        store.saveResumeData(nil)
        XCTAssertFalse(store.hasResumeData, "nil clears it")
    }

    func testSpaceCheck() throws {
        let manifest = ModelManifest(fileName: "m.gguf", sha256: String(repeating: "0", count: 64),
                                     bytes: 91_893_088, url: URL(string: "https://example.com/m.gguf")!)
        let store = store(manifest)
        XCTAssertNoThrow(try store.checkSpace(free: nil), "unknown free space: let the download try")
        XCTAssertNoThrow(try store.checkSpace(free: 200_000_000))
        XCTAssertThrowsError(try store.checkSpace(free: 100_000_000)) { error in
            XCTAssertEqual(error as? ModelInstallError, .notEnoughSpace(needed: 116_893_088, available: 100_000_000))
            XCTAssertEqual("\(error)", "Needs about 117 MB free. The watch has 100 MB.")
        }
        XCTAssertNoThrow(try store.checkSpace(free: 100_000_000, alreadyReceived: 50_000_000),
                         "a resumed download needs only the rest")
        XCTAssertNotNil(store.freeBytes())
    }

    /// Without a downloaded model, "not covered" replies don't point at a button that isn't there.
    func testNotCoveredReplyMentionsTheModelOnlyWhenOneIsInstalled() throws {
        let log = try EventLog(fileURL: dir.appendingPathComponent("events.jsonl"), device: DeviceID("watch"))
        let s = KITTSession(log: log, pack: try ContentPack.bundled())
        s.modelAvailable = false
        guard case let .answered(without) = try s.send("What are the best hiking boots?") else { return XCTFail() }
        XCTAssertEqual(without.text, "The guide doesn't cover that yet. Browse the topics.")
        XCTAssertTrue(without.offersModel, "still recorded as unanswered, so a model downloaded later can take it")
        s.modelAvailable = true
        s.startNewConversation()
        guard case let .answered(with) = try s.send("What are the best hiking boots?") else { return XCTFail() }
        XCTAssertEqual(with.text, "The guide doesn't cover that yet. Browse the topics, or ask the model for an unverified answer.")
    }
}
