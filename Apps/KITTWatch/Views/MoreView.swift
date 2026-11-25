import SwiftUI
import KITTCore

struct MoreView: View {
    @EnvironmentObject private var model: AppModel

    let onBrowse: () -> Void
    let onNew: () -> Void

    var body: some View {
        List {
            Button("Browse guide", action: onBrowse)
            NavigationLink("Household") { HouseholdView() }
            Button("New conversation", action: onNew).disabled(model.isGenerating)
            Section {
                Toggle("Read replies aloud", isOn: $model.readAloud)
            } footer: {
                Text("While KITT is speaking, a stop square is at the top of every screen.")
            }
            NavigationLink("Measurements") { MetricsView() }
            NavigationLink("Benchmark") { BenchmarkView() }
            NavigationLink("Guide pack") { GuidePackView() }
            NavigationLink("About & licenses") { AboutView() }
        }
        .navigationTitle("More")
    }
}

struct SourceView: View {
    let entry: GuideEntry
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.headline)
                Text(entry.shortAnswer).font(.footnote)
                Divider()
                ForEach(entry.sources, id: \.url) { source in
                    Text(source.publisher).font(.footnote).bold()
                    Text(source.title).font(.footnote)
                    Text(source.url).font(.caption2).foregroundStyle(.secondary)
                    Text("Checked \(source.retrieved)").font(.caption2).foregroundStyle(.secondary)
                }
                Text("Entry \(entry.citation) · review: \(entry.review.status.rawValue)")
                    .font(.caption2).foregroundStyle(entry.review.status == .reviewed ? Color.secondary : Color.orange)
            }
        }
        .navigationTitle("Source")
    }
}

struct GuidePackView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List(model.pack.entries) { e in
            NavigationLink { SourceView(entry: e) } label: {
                VStack(alignment: .leading) {
                    Text(e.title).font(.footnote)
                    Text(e.topic).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("\(model.pack.title) v\(model.pack.version)")
    }
}

struct MetricsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var entries: [MetricsRecorder.Entry] = []

    var body: some View {
        List(entries) { e in
            VStack(alignment: .leading, spacing: 2) {
                Text(e.kind).font(.footnote).bold()
                Text(e.time, style: .time).font(.caption2).foregroundStyle(.secondary)
                Text(summary(e)).font(.caption2)
            }
        }
        .navigationTitle("Measurements")
        .onAppear { entries = model.metrics.recent() }
    }

    private func summary(_ e: MetricsRecorder.Entry) -> String {
        let keys = ["ms", "prewarm_ms", "ttft_ms", "tokens_per_second", "prompt_tokens", "reused_tokens", "prefill_tokens_per_second", "peak_footprint_mb", "footprint_mb", "available_mb", "battery_start", "battery_end"]
        return keys.compactMap { k in e.values[k].map { "\(k)=\(String(format: "%.1f", $0))" } }.joined(separator: " ")
    }
}

/// Runs the fixed prompt in AppModel's Benchmark, outside the conversation, so the
/// transcript stays clean and runs are comparable across builds and models.
struct BenchmarkView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs a fixed guide question through the model and records timing, memory, and battery. The first run includes loading the model.")
                    .font(.caption2)
                Button("Run benchmark") { model.runBenchmark() }
                    .disabled(model.isGenerating)
                if let result = model.lastBenchmark {
                    Text(result).font(.footnote).monospacedDigit()
                }
            }
        }
        .navigationTitle("Benchmark")
    }
}

struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("KITT").font(.headline)
                Text("Offline preparedness assistant. Answers marked Guide are the guide entry's own text. Model replies are unverified and only appear when you ask for one.")
                    .font(.footnote)
                Text("llama.cpp — MIT License, © The ggml authors.").font(.caption2)
                Text("SmolLM2-135M-Instruct — Apache License 2.0, © Hugging Face.").font(.caption2)
                Text("Guide text paraphrases Ready.gov (FEMA) and CDC guidance; each entry links its source.").font(.caption2)
                Text("Full notices are in NOTICE.md in the source repository.").font(.caption2).foregroundStyle(.secondary)
                Text(ModelLocator.describedModel).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
    }
}
