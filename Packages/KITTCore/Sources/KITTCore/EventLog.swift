import Foundation

/// Append-only, newline-delimited JSON log of conversation events on this device.
///
/// - Every append is flushed to disk (fsync) before it returns, so a turn the UI shows
///   as saved survives the app being killed.
/// - A torn last line (power loss mid-write) is skipped on load, not fatal.
/// - Events are deduplicated by ID, so replaying a delivery five times yields one event.
public final class EventLog: @unchecked Sendable {
    public let fileURL: URL
    public let device: DeviceID
    private let lock = NSLock()
    private var events: [ConversationEvent] = []
    private var ids: Set<UUID> = []
    private var nextSequence: Int64 = 1

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Number of unreadable lines skipped on load (diagnostic).
    public private(set) var skippedLines = 0

    public init(fileURL: URL, device: DeviceID) throws {
        self.fileURL = fileURL
        self.device = device
        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) {
            _ = fm.createFile(atPath: fileURL.path, contents: nil)
        }
        try load()
    }

    private func load() throws {
        let data = try Data(contentsOf: fileURL)
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            guard let e = try? Self.decoder.decode(ConversationEvent.self, from: Data(line)) else {
                skippedLines += 1
                continue
            }
            insertLoaded(e)
        }
    }

    private func insertLoaded(_ e: ConversationEvent) {
        guard ids.insert(e.id).inserted else { return }
        events.append(e)
        if e.device == device { nextSequence = max(nextSequence, e.localSequence + 1) }
    }

    // MARK: Reading

    public var all: [ConversationEvent] { lock.lock(); defer { lock.unlock() }; return events }

    public func events(in conversation: UUID) -> [ConversationEvent] {
        all.filter { $0.conversationID == conversation }
    }

    public var conversationIDs: [UUID] {
        var seen = Set<UUID>(), out: [UUID] = []
        for e in all where seen.insert(e.conversationID).inserted { out.append(e.conversationID) }
        return out
    }

    /// Last event in a conversation by local append order (used as the next parent).
    public func head(of conversation: UUID) -> ConversationEvent? {
        events(in: conversation).last
    }

    // MARK: Writing

    /// Create and durably save a new local event.
    @discardableResult
    public func append(_ payload: EventPayload, conversation: UUID, now: Date = Date()) throws -> ConversationEvent {
        lock.lock(); defer { lock.unlock() }
        let parent = events.last(where: { $0.conversationID == conversation })?.id
        let e = ConversationEvent(conversationID: conversation, parentID: parent, device: device,
                                  localSequence: nextSequence, timestamp: now, payload: payload)
        try write(e)
        nextSequence += 1
        return e
    }

    /// Accept events that arrived from another device. Returns the ones that were new.
    /// Idempotent: duplicates (same event ID) are ignored.
    @discardableResult
    public func ingest(_ incoming: [ConversationEvent]) throws -> [ConversationEvent] {
        lock.lock(); defer { lock.unlock() }
        var added: [ConversationEvent] = []
        for e in incoming where !ids.contains(e.id) {
            try write(e)
            added.append(e)
        }
        return added
    }

    private func write(_ e: ConversationEvent) throws {
        var line = try Self.encoder.encode(e)
        line.append(UInt8(ascii: "\n"))
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
        ids.insert(e.id)
        events.append(e)
    }
}
