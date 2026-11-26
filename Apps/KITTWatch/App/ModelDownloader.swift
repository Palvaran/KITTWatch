import Foundation
import KITTCore

/// Downloads one optional file in a background URLSession, so the transfer carries on when
/// the wrist is lowered and KITT is suspended: the offline model, or a guide voice pack.
/// Nothing else waits on them: guide answers, warnings, the water calculator and the Apple
/// voice work the same with or without them.
///
/// The files, the checksum and "keep the working file until the new one verifies" live in
/// KITTCore's ModelStore, where they are tested. This class only moves bytes and reports.
final class ModelDownloader: NSObject, @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case downloading(received: Int64, total: Int64)
        /// The download arrived; its SHA-256 is being checked.
        case verifying
        /// Cancel was tapped. What arrived is kept for Resume.
        case paused(received: Int64)
        case failed(String)
    }

    /// The offline model (More › Offline model).
    static let shared = ModelDownloader(sessionID: "com.palvaran.kitt.model-download",
                                        infoPrefix: "KITTModel", folder: "KITT/Models")
    /// The guide voice packs (More › Voice).
    static let heartVoice = ModelDownloader(sessionID: "com.palvaran.kitt.voice-heart",
                                            infoPrefix: "KITTVoiceHeart", folder: "KITT/Voices/Heart")
    static let michaelVoice = ModelDownloader(sessionID: "com.palvaran.kitt.voice-michael",
                                              infoPrefix: "KITTVoiceMichael", folder: "KITT/Voices/Michael")

    /// The background session's identifier; KITTWatchApp wakes for each one.
    let sessionID: String
    /// nil when the build's Info.plist has no manifest for this file.
    let store: ModelStore?

    /// Runs on the main queue after every change of phase or installed model.
    var onChange: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var _phase: Phase = .idle
    private var received: Int64 = 0
    private var lastReport = Date.distantPast
    private var userCancelled = false
    private var serverFailure: String?
    private var eventWaiters: [CheckedContinuation<Void, Never>] = []
    private var session: URLSession!

    var phase: Phase { locked { _phase } }

    private init(sessionID: String, infoPrefix: String, folder: String) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent(folder, isDirectory: true)
        self.sessionID = sessionID
        store = ModelManifest(infoDictionary: Bundle.main.infoDictionary ?? [:], prefix: infoPrefix)
            .map { ModelStore(directory: directory, manifest: $0) }
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: sessionID)
        configuration.isDiscretionary = false        // the user asked for it now
        configuration.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = sessionID
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        reconcile()
    }

    // MARK: Actions

    /// Download the file this build pins, continuing a paused or dropped download when it
    /// can. Calling it while a download is running does nothing.
    func start() {
        guard let store else { return }
        switch phase {
        case .downloading, .verifying: return
        default: break
        }
        let resumeData = store.takeResumeData()
        do {
            try store.checkSpace(free: store.freeBytes(), alreadyReceived: resumeData == nil ? 0 : locked { received })
        } catch {
            store.saveResumeData(resumeData)   // keep it for when there is room
            setPhase(.failed(Self.describe(error)))
            return
        }
        locked { userCancelled = false; serverFailure = nil; if resumeData == nil { received = 0 } }
        setPhase(.downloading(received: locked { received }, total: store.manifest.bytes))
        session.getAllTasks { tasks in
            if tasks.contains(where: { $0.state == .running }) { return }
            tasks.forEach { $0.cancel() }
            let task = resumeData.map { self.session.downloadTask(withResumeData: $0) }
                ?? self.session.downloadTask(with: store.manifest.url)
            task.countOfBytesClientExpectsToReceive = store.manifest.bytes
            task.resume()
        }
    }

    /// Stop the transfer and keep what arrived, so Resume continues from there. watchOS
    /// doesn't always hand back resume data; then the next download starts from zero, and
    /// the screen says so (it reports the phase only after the data, if any, is saved).
    func cancel() {
        locked { userCancelled = true }
        session.getAllTasks { tasks in
            if tasks.isEmpty { self.setPhase(.paused(received: self.locked { self.received })) }
            for task in tasks {
                if let download = task as? URLSessionDownloadTask {
                    download.cancel(byProducingResumeData: { data in
                        if let data { self.store?.saveResumeData(data) }
                        self.setPhase(.paused(received: self.locked { self.received }))
                    })
                } else {
                    task.cancel()
                }
            }
        }
    }

    /// Remove the file and anything half-downloaded. Guide answers keep working.
    func delete() throws {
        try store?.delete()
        locked { received = 0 }
        setPhase(.idle)
    }

    /// The system woke KITT for this session's events (the download finished or failed
    /// while KITT was suspended). Returns once they have been delivered, or after 25 s.
    func handleBackgroundEvents() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locked { eventWaiters.append(continuation) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25) { self.resumeEventWaiters() }
        }
    }

    // MARK: State

    /// After a launch: finish a check an earlier launch didn't, and pick up a transfer
    /// that kept running while KITT was not.
    private func reconcile() {
        guard let store else { return }
        if store.hasPendingFile {
            setPhase(.verifying)
            DispatchQueue.global(qos: .utility).async {
                do {
                    try store.finishPendingInstall()
                    self.setPhase(.idle)
                } catch {
                    self.setPhase(.failed(Self.describe(error)))
                }
            }
        }
        session.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.state == .running || $0.state == .suspended }) else { return }
            if task.state == .suspended { task.resume() }
            let total = task.countOfBytesExpectedToReceive > 0 ? task.countOfBytesExpectedToReceive : store.manifest.bytes
            self.locked { self.received = task.countOfBytesReceived }
            self.setPhase(.downloading(received: task.countOfBytesReceived, total: total))
        }
    }

    private func setPhase(_ phase: Phase) {
        locked { _phase = phase }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onChange?() }
        }
    }

    private func resumeEventWaiters() {
        let waiters: [CheckedContinuation<Void, Never>] = locked {
            defer { eventWaiters = [] }
            return eventWaiters
        }
        waiters.forEach { $0.resume() }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// One sentence for the watch screen.
    static func describe(_ error: Error) -> String {
        if let install = error as? ModelInstallError { return install.description }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                return "The connection dropped. Resume when the watch is on Wi-Fi or near your iPhone."
            case .cancelled:
                return "The download stopped. Resume continues where it stopped."
            default:
                break
            }
        }
        return "The download stopped: \(error.localizedDescription)"
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (store?.manifest.bytes ?? 0)
        let now = Date()
        let report: Bool = locked {
            received = totalBytesWritten
            guard now.timeIntervalSince(lastReport) >= 0.25 || totalBytesWritten == total else { return false }
            lastReport = now
            return true
        }
        if report { setPhase(.downloading(received: totalBytesWritten, total: total)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didResumeAtOffset fileOffset: Int64,
                    expectedTotalBytes: Int64) {
        locked { received = fileOffset }
        setPhase(.downloading(received: fileOffset,
                              total: expectedTotalBytes > 0 ? expectedTotalBytes : (store?.manifest.bytes ?? 0)))
    }

    /// The file at `location` is deleted when this returns, so ModelStore moves it first.
    /// Verification then runs here, before the system is told the session's events are done.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let store else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            store.saveResumeData(nil)   // a fresh start is the only way on
            locked { serverFailure = "The download server answered \(http.statusCode). Try again later." }
            return
        }
        setPhase(.verifying)
        do {
            try store.install(downloadedFile: location)
            setPhase(.idle)
        } catch {
            setPhase(.failed(Self.describe(error)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (cancelledByUser, failure): (Bool, String?) = locked {
            defer { serverFailure = nil }
            return (userCancelled, serverFailure)
        }
        if let failure { setPhase(.failed(failure)); return }
        guard let error else { return }   // success: didFinishDownloadingTo already reported
        if let data = (error as? URLError)?.downloadTaskResumeData { store?.saveResumeData(data) }
        if (error as? URLError)?.code == .cancelled, cancelledByUser {
            setPhase(.paused(received: locked { received }))
        } else {
            setPhase(.failed(Self.describe(error)))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        resumeEventWaiters()
    }
}
