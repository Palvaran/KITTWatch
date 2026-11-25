import Foundation
import KITTCore
import WatchKit
import os

/// Milestone 1 measurements: launch, model load, first answer, sustained generation,
/// memory, battery, and lifecycle. One JSON object per line in metrics.jsonl.
/// Pull the file with Xcode › Devices and Simulators › KITT › Download Container.
final class MetricsRecorder: @unchecked Sendable {
    struct Entry: Codable, Identifiable {
        var id: UUID = UUID()
        var kind: String
        var time: Date
        var values: [String: Double]
    }

    let fileURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys; return e
    }()

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        DispatchQueue.main.async { WKInterfaceDevice.current().isBatteryMonitoringEnabled = true }
    }

    func record(_ kind: String, _ values: [String: Double] = [:]) {
        var v = values
        v["footprint_mb"] = v["footprint_mb"] ?? Self.footprintMB()
        v["thermal_state"] = Double(ProcessInfo.processInfo.thermalState.rawValue)
        append(Entry(kind: kind, time: Date(), values: v))
    }

    func record(generation s: GenerationStats, peakFootprintMB: Double, batteryStart: Double) {
        record("generation", [
            "prompt_tokens": Double(s.promptTokens),
            "generated_tokens": Double(s.generatedTokens),
            "reused_tokens": Double(s.reusedTokens),
            "prefill_ms": s.prefillMilliseconds,
            "prefill_tokens_per_second": s.prefillTokensPerSecond,
            "ttft_ms": s.timeToFirstTokenMilliseconds ?? -1,
            "generation_ms": s.generationMilliseconds,
            "tokens_per_second": s.tokensPerSecond,
            "peak_footprint_mb": peakFootprintMB,
            "available_mb": Self.availableMB(),
            "battery_start": batteryStart,
            "battery_end": batteryLevel(),
            "cancelled": s.stop == .cancelled ? 1 : 0,
        ])
    }

    func recent(_ n: Int = 30) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return data.split(separator: UInt8(ascii: "\n")).suffix(n).compactMap { try? d.decode(Entry.self, from: Data($0)) }.reversed()
    }

    private func append(_ e: Entry) {
        lock.lock(); defer { lock.unlock() }
        guard var line = try? encoder.encode(e), let h = try? FileHandle(forWritingTo: fileURL) else { return }
        line.append(UInt8(ascii: "\n"))
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }

    // MARK: Probes

    /// Battery 0–1, or -1 when unknown. WatchKit is main-thread only.
    func batteryLevel() -> Double {
        if Thread.isMainThread { return Double(WKInterfaceDevice.current().batteryLevel) }
        return DispatchQueue.main.sync { Double(WKInterfaceDevice.current().batteryLevel) }
    }

    /// The figure jetsam uses for this process.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Headroom before the system terminates the app for memory.
    static func availableMB() -> Double { Double(os_proc_available_memory()) / 1_048_576 }

    /// Samples footprint every 200 ms so load/prefill peaks are not missed.
    func startMemorySampler() -> MemorySampler { MemorySampler() }

    final class MemorySampler: @unchecked Sendable {
        private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "kitt.memsample", qos: .utility))
        private let lock = NSLock()
        private var peak = MetricsRecorder.footprintMB()
        init() {
            timer.schedule(deadline: .now(), repeating: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let v = MetricsRecorder.footprintMB()
                self.lock.lock(); self.peak = max(self.peak, v); self.lock.unlock()
            }
            timer.resume()
        }
        func stop() -> Double {
            timer.cancel()
            lock.lock(); defer { lock.unlock() }
            return max(peak, MetricsRecorder.footprintMB())
        }
    }
}
