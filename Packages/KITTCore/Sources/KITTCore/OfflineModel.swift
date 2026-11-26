import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The model a build of KITT downloads. The four values are pinned in scripts/versions.env
/// and copied into the watch app's Info.plist; a pre-build check keeps the two equal.
public struct ModelManifest: Equatable, Sendable, Codable {
    public var fileName: String
    /// Lowercase hex SHA-256 of the whole file.
    public var sha256: String
    public var bytes: Int64
    public var url: URL

    public init(fileName: String, sha256: String, bytes: Int64, url: URL) {
        self.fileName = fileName
        self.sha256 = sha256.lowercased()
        self.bytes = bytes
        self.url = url
    }

    /// Reads KITTModelFile, KITTModelSHA256, KITTModelBytes and KITTModelURL. Another
    /// downloadable file uses its own prefix: "KITTVoiceHeart" reads KITTVoiceHeartFile and so on.
    public init?(infoDictionary info: [String: Any], prefix: String = "KITTModel") {
        guard let file = info[prefix + "File"] as? String, !file.isEmpty,
              let sha = info[prefix + "SHA256"] as? String, sha.count == 64,
              let link = info[prefix + "URL"] as? String, let url = URL(string: link),
              let bytes = Self.int64(info[prefix + "Bytes"]), bytes > 0
        else { return nil }
        self.init(fileName: file, sha256: sha, bytes: bytes, url: url)
    }

    /// "SmolLM2-135M-Instruct-Q4_0@bcc3af28": saved with every model reply.
    public var id: String { ModelManifest.id(fileName: fileName, sha256: sha256) }

    /// The download size the way the watch shows it: "92 MB".
    public var sizeLabel: String { ModelManifest.megabytes(bytes) }

    static func id(fileName: String, sha256: String) -> String {
        let name = (fileName as NSString).deletingPathExtension
        return "\(name)@\(sha256.prefix(8))"
    }

    public static func megabytes(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
    }

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as NSNumber: return v.int64Value
        case let v as String: return Int64(v)
        default: return nil
        }
    }
}

/// A model that passed verification. Written only after the file's size and SHA-256
/// matched the manifest it was downloaded for.
public struct InstalledModel: Equatable, Sendable, Codable {
    public var fileName: String
    public var sha256: String
    public var bytes: Int64
    public var verifiedAt: Date

    public var id: String { ModelManifest.id(fileName: fileName, sha256: sha256) }

    /// Whether this is the model the manifest asks for.
    public func matches(_ manifest: ModelManifest) -> Bool {
        fileName == manifest.fileName && sha256 == manifest.sha256 && bytes == manifest.bytes
    }
}

public enum ModelInstallError: Error, Equatable, CustomStringConvertible {
    case noDownload
    case wrongSize(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)
    case notEnoughSpace(needed: Int64, available: Int64)

    /// One sentence for the watch screen.
    public var description: String {
        switch self {
        case .noDownload:
            return "The download didn't arrive. Try again."
        case .wrongSize, .checksumMismatch:
            return "The download didn't match the expected file, so KITT deleted it. Try again."
        case let .notEnoughSpace(needed, available):
            return "Needs about \(ModelManifest.megabytes(needed)) free. The watch has \(ModelManifest.megabytes(available))."
        }
    }
}

/// The offline model's files, under Application Support/KITT/Models:
///
///     installed.json        the verified model (InstalledModel)
///     <name>.gguf           that model
///     incoming/<name>.gguf  a finished download waiting for its checksum
///     incoming/resume.data  where an interrupted download can continue from
///
/// A new download never touches the installed model until it has passed verification,
/// so an interrupted or bad download leaves a working model working.
public final class ModelStore: @unchecked Sendable {
    public let directory: URL
    public let manifest: ModelManifest
    /// Room kept free beyond the download itself.
    public static let spaceMargin: Int64 = 25_000_000

    private let lock = NSLock()
    private let fm = FileManager.default

    public init(directory: URL, manifest: ModelManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    var markerURL: URL { directory.appendingPathComponent("installed.json") }
    var incomingDirectory: URL { directory.appendingPathComponent("incoming", isDirectory: true) }
    /// Where a finished download waits for verification.
    public var pendingURL: URL { incomingDirectory.appendingPathComponent(manifest.fileName) }
    public var resumeDataURL: URL { incomingDirectory.appendingPathComponent("resume.data") }

    // MARK: Reading

    /// The verified model, if its file is still there at the size that was verified.
    public var installed: InstalledModel? {
        guard let data = try? Data(contentsOf: markerURL),
              let model = try? Self.decoder.decode(InstalledModel.self, from: data),
              size(of: directory.appendingPathComponent(model.fileName)) == model.bytes
        else { return nil }
        return model
    }

    /// The file to load, if a verified model is installed.
    public var installedURL: URL? {
        installed.map { directory.appendingPathComponent($0.fileName) }
    }

    /// A verified model is installed but it isn't the one this build asks for.
    public var hasUpdate: Bool {
        guard let installed else { return false }
        return !installed.matches(manifest)
    }

    public var hasPendingFile: Bool { fm.fileExists(atPath: pendingURL.path) }

    // MARK: Space

    /// Bytes the download needs free on the watch, margin included.
    public var bytesNeeded: Int64 { manifest.bytes + Self.spaceMargin }

    /// Free space on the volume that holds the models, if the system reports it.
    public func freeBytes() -> Int64? {
        try? ensureDirectories()
        guard let attributes = try? fm.attributesOfFileSystem(forPath: directory.path),
              let free = attributes[.systemFreeSize] as? NSNumber
        else { return nil }
        return free.int64Value
    }

    /// Throws `.notEnoughSpace` when the download would not fit. A partial download
    /// already on disk counts against what is still needed.
    public func checkSpace(free: Int64?, alreadyReceived: Int64 = 0) throws {
        guard let free else { return }   // unknown: let the download try
        let needed = bytesNeeded - max(0, min(alreadyReceived, manifest.bytes))
        if free < needed { throw ModelInstallError.notEnoughSpace(needed: needed, available: free) }
    }

    // MARK: Installing

    /// Take a finished download, verify it and install it. The download is moved out of
    /// `file` immediately, as URLSession requires; verification then runs on the moved copy.
    /// On any failure the download is deleted and the installed model is left as it was.
    @discardableResult
    public func install(downloadedFile file: URL) throws -> InstalledModel {
        try lock.locked {
            try ensureDirectories()
            if fm.fileExists(atPath: pendingURL.path) { try fm.removeItem(at: pendingURL) }
            try fm.moveItem(at: file, to: pendingURL)
            return try verifyAndInstallPendingLocked()
        }
    }

    /// Finish what an interrupted launch left behind: a download that arrived but was not
    /// verified yet. Returns the newly installed model, or nil if there was nothing to do.
    @discardableResult
    public func finishPendingInstall() throws -> InstalledModel? {
        try lock.locked {
            guard fm.fileExists(atPath: pendingURL.path) else { return nil }
            return try verifyAndInstallPendingLocked()
        }
    }

    private func verifyAndInstallPendingLocked() throws -> InstalledModel {
        let actualSize = size(of: pendingURL) ?? -1
        guard actualSize == manifest.bytes else {
            try? fm.removeItem(at: pendingURL)
            throw ModelInstallError.wrongSize(expected: manifest.bytes, actual: actualSize)
        }
        let digest = try Self.sha256(of: pendingURL)
        guard digest == manifest.sha256 else {
            try? fm.removeItem(at: pendingURL)
            throw ModelInstallError.checksumMismatch(expected: manifest.sha256, actual: digest)
        }

        // Verified. Put it in place, then point the marker at it, then remove the old model.
        let previous = installedLocked()
        let destination = directory.appendingPathComponent(manifest.fileName)
        // rename(2) replaces an existing file of the same name in one step.
        guard rename(pendingURL.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        Self.excludeFromBackup(destination)
        let model = InstalledModel(fileName: manifest.fileName, sha256: manifest.sha256,
                                   bytes: manifest.bytes,
                                   verifiedAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        try Self.encoder.encode(model).write(to: markerURL, options: .atomic)
        if let previous, previous.fileName != model.fileName {
            try? fm.removeItem(at: directory.appendingPathComponent(previous.fileName))
        }
        try? fm.removeItem(at: resumeDataURL)
        return model
    }

    private func installedLocked() -> InstalledModel? { installed }

    // MARK: Removing

    /// Remove the installed model and anything half-downloaded.
    public func delete() throws {
        try lock.locked {
            if let model = installed {
                try? fm.removeItem(at: directory.appendingPathComponent(model.fileName))
            }
            if fm.fileExists(atPath: markerURL.path) { try fm.removeItem(at: markerURL) }
            if fm.fileExists(atPath: incomingDirectory.path) { try fm.removeItem(at: incomingDirectory) }
            // Any other model file left by an older build.
            for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            where file.pathExtension == "gguf" {
                try? fm.removeItem(at: file)
            }
        }
    }

    // MARK: Resume data

    public func saveResumeData(_ data: Data?) {
        lock.locked {
            guard let data, !data.isEmpty else { try? fm.removeItem(at: resumeDataURL); return }
            try? ensureDirectories()
            try? data.write(to: resumeDataURL, options: .atomic)
        }
    }

    /// The saved resume data, removed as it is handed out (it is only good once).
    public func takeResumeData() -> Data? {
        lock.locked {
            defer { try? fm.removeItem(at: resumeDataURL) }
            return try? Data(contentsOf: resumeDataURL)
        }
    }

    public var hasResumeData: Bool { fm.fileExists(atPath: resumeDataURL.path) }

    // MARK: Helpers

    private func ensureDirectories() throws {
        try fm.createDirectory(at: incomingDirectory, withIntermediateDirectories: true)
        Self.excludeFromBackup(directory)
    }

    private func size(of url: URL) -> Int64? {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    /// The model can be downloaded again, so it stays out of the watch's backups.
    private static func excludeFromBackup(_ url: URL) {
        #if canImport(Darwin)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        #endif
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Lowercase hex SHA-256 of some bytes.
    public static func sha256(of data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = PortableSHA256()
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #endif
    }

    /// Lowercase hex SHA-256 of a file, read in 1 MB pieces so memory stays flat.
    /// CryptoKit on Apple platforms; a plain Swift implementation elsewhere (tests on Linux).
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if canImport(CryptoKit)
        var hasher = CryptoKit.SHA256()
        #else
        var hasher = PortableSHA256()
        #endif
        while true {
            let more: Bool = try withPool {
                guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@inline(__always)
private func withPool<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(ObjectiveC)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// SHA-256 (FIPS 180-4) in plain Swift, for platforms without CryptoKit.
public struct PortableSHA256 {
    private var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer: [UInt8] = []
    private var length: UInt64 = 0

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    public init() {}

    public mutating func update(data: Data) {
        length &+= UInt64(data.count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            if !buffer.isEmpty {
                let take = min(64 - buffer.count, bytes.count)
                buffer.append(contentsOf: bytes[0..<take])
                index = take
                if buffer.count == 64 {
                    buffer.withUnsafeBufferPointer { compress($0.baseAddress!) }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            while index + 64 <= bytes.count {
                compress(bytes.baseAddress! + index)
                index += 64
            }
            if index < bytes.count { buffer.append(contentsOf: bytes[index...]) }
        }
    }

    public mutating func finalize() -> [UInt8] {
        let bitLength = length &* 8
        var tail = buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { tail.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift))) }
        tail.withUnsafeBufferPointer { p in
            var offset = 0
            while offset < p.count { compress(p.baseAddress! + offset); offset += 64 }
        }
        buffer.removeAll()
        return h.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) } }
    }

    private mutating func compress(_ block: UnsafePointer<UInt8>) {
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { w in compress(block, w) }
    }

    private mutating func compress(_ block: UnsafePointer<UInt8>, _ w: UnsafeMutableBufferPointer<UInt32>) {
        for i in 0..<16 {
            w[i] = UInt32(block[4 * i]) << 24 | UInt32(block[4 * i + 1]) << 16
                 | UInt32(block[4 * i + 2]) << 8 | UInt32(block[4 * i + 3])
        }
        for i in 16..<64 {
            let s0 = w[i - 15].rotatedRight(7) ^ w[i - 15].rotatedRight(18) ^ (w[i - 15] >> 3)
            let s1 = w[i - 2].rotatedRight(17) ^ w[i - 2].rotatedRight(19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
        for i in 0..<64 {
            let s1 = e.rotatedRight(6) ^ e.rotatedRight(11) ^ e.rotatedRight(25)
            let ch = (e & f) ^ (~e & g)
            let t1 = hh &+ s1 &+ ch &+ Self.k[i] &+ w[i]
            let s0 = a.rotatedRight(2) ^ a.rotatedRight(13) ^ a.rotatedRight(22)
            let maj = (a & b) ^ (a & c) ^ (b & c)
            let t2 = s0 &+ maj
            hh = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d
        h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
    }
}

private extension UInt32 {
    @inline(__always) func rotatedRight(_ n: UInt32) -> UInt32 { (self >> n) | (self << (32 - n)) }
}
