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
            NavigationLink { OfflineModelView().stopSpeakingButton() } label: {
                VStack(alignment: .leading) {
                    Text("Offline model")
                    Text(model.modelSummary).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Button("New conversation", action: onNew).disabled(model.isGenerating)
            Section {
                Toggle("Read replies aloud", isOn: $model.readAloud)
                NavigationLink("Voice") { VoiceView().stopSpeakingButton() }
            } footer: {
                Text("While KITT is speaking, a stop square is at the top of every screen.")
            }
            NavigationLink("Measurements") { MetricsView() }
            NavigationLink("Benchmark") { BenchmarkView() }
            NavigationLink("Guide pack") { GuidePackView() }
            Section {
                NavigationLink("About & licenses") { AboutView() }
            } footer: {
                Text("\(AppModel.buildLabel) · guide v\(model.pack.version)")
            }
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
                    .disabled(model.isGenerating || model.installedModel == nil)
                if model.installedModel == nil {
                    Text("Download the offline model first: More › Offline model.").font(.caption2).foregroundStyle(.secondary)
                }
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
                Text(AppModel.buildLabel).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
    }
}

/// Choose the voice and speed. Every choice plays the same sample line, so voices can be
/// compared by ear on the watch itself.
struct VoiceView: View {
    @EnvironmentObject private var model: AppModel
    @State private var failedSample: String?

    var body: some View {
        List {
            Section {
                Picker("Reply voice", selection: selectedVoice) {
                    Text("Apple default").tag("apple-default")
                    ForEach(GuideVoice.recorded.filter { model.installedVoices.contains($0) }, id: \.self) { voice in
                        Text(voice.rawValue + " (Kokoro)").tag("kokoro-" + voice.rawValue)
                    }
                    ForEach(model.voiceOptions) { voice in
                        Text(voice.name + " · " + voice.detail).tag(voice.id)
                    }
                }
            } footer: {
                Text("Applies to every conversation. Heart and Michael read guide answers once downloaded. Your Apple voice reads model replies and anything without a recording.")
            }
            Section {
                ForEach(GuideVoice.recorded, id: \.self) { voice in
                    NavigationLink { VoicePackView(voice: voice).stopSpeakingButton() } label: {
                        VStack(alignment: .leading) {
                            Text(voice.rawValue + " (Kokoro)")
                            Text(model.voiceSummary(voice)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Guide voices")
            } footer: {
                Text("Optional downloads. Recorded guide answers in a natural voice.")
            }
            Section {
                Picker("Speed", selection: $model.slowerSpeech) {
                    Text("Normal").tag(false)
                    Text("Slower").tag(true)
                }
                Button { model.playVoiceSample() } label: {
                    Label("Hear sample", systemImage: "play.circle")
                }
            } footer: {
                Text("\u{201C}\(AppModel.voiceSample)\u{201D}")
            }
            NavigationLink("Hear Kokoro") {
                KokoroSamplesView(play: model.playRecordedSample).stopSpeakingButton()
            }
            Section {
                sampleRows(["Jasper", "Bella"], prefix: "Kitten")
            } header: {
                Text("KittenTTS trial")
            } footer: {
                Text("These are recorded samples. Your selected voice reads replies.")
            }
        }
        .navigationTitle("Voice")
        .onChange(of: model.slowerSpeech) { _, _ in model.playVoiceSample() }
    }

    private func sampleRows(_ voices: [String], prefix: String, fileExtension: String = "wav") -> some View {
        ForEach(voices, id: \.self) { voice in
            let resource = "\(prefix)-\(voice)"
            Button {
                failedSample = model.playRecordedSample(resource, fileExtension: fileExtension) ? nil : resource
            } label: {
                Label(voice, systemImage: "play.circle")
            }
            if failedSample == resource { Text("Couldn’t play the sample.").font(.caption2) }
        }
    }

    private var selectedVoice: Binding<String> {
        Binding(get: {
            // A recorded voice reads only once downloaded; until then the Apple voice does.
            model.installedVoices.contains(model.guideVoice)
                ? "kokoro-" + model.guideVoice.rawValue : (model.voiceID ?? "apple-default")
        }, set: { id in
            switch id {
            case "kokoro-Heart": model.guideVoice = .heart
            case "kokoro-Michael": model.guideVoice = .michael
            default:
                model.voiceID = id == "apple-default" ? nil : id
                model.guideVoice = .system
            }
            model.playVoiceSample()
        })
    }
}

/// More › Offline model. The model is optional: it adds "Ask the model anyway" under
/// questions the guide doesn't cover. Guide answers, warnings, the water calculator and
/// speech work without it, before, during and after a download.
struct OfflineModelView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let manifest = model.modelManifest {
                    content(manifest)
                } else {
                    Text("This build has no offline model to download.").font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Offline model")
        .confirmationDialog("Delete the offline model?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteModel() }
        } message: {
            Text("Guide answers keep working. You can download it again.")
        }
    }

    @ViewBuilder private func content(_ manifest: ModelManifest) -> some View {
        if let installed = model.installedModel {
            Label("Ready offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text(installed.id).font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("Optional. Adds \u{201C}Ask the model anyway\u{201D} under questions the guide doesn't cover. Guide answers, warnings and the water calculator work without it.")
                .font(.footnote)
        }
        DownloadControls(manifest: manifest, phase: model.modelPhase, installed: model.installedModel != nil,
                         hasUpdate: model.modelHasUpdate, canResume: model.canResumeModelDownload,
                         updateNote: "A newer model is available. KITT keeps using this one until the new one has downloaded and checked out.",
                         deleteLabel: "Delete model", deleteDisabled: model.isGenerating,
                         download: { model.downloadModel() }, cancel: { model.cancelModelDownload() },
                         delete: { confirmingDelete = true })
    }
}

/// More › Voice › Heart or Michael: download, update or delete one guide voice.
struct VoicePackView: View {
    @EnvironmentObject private var model: AppModel
    let voice: GuideVoice
    @State private var confirmingDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let manifest = model.voiceManifest(voice) {
                    content(manifest)
                } else {
                    Text("This build has no \(voice.rawValue) voice to download.").font(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(voice.rawValue)
        .confirmationDialog("Delete the \(voice.rawValue) voice?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { model.deleteVoice(voice) }
        } message: {
            Text("Your Apple voice reads replies instead. You can download it again.")
        }
    }

    @ViewBuilder private func content(_ manifest: ModelManifest) -> some View {
        let installed = model.installedVoices.contains(voice)
        if installed {
            Label("Ready offline", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if model.guideVoice == voice {
                Text("Reads guide answers.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Button("Use for replies") {
                    model.guideVoice = voice
                    model.playVoiceSample()
                }
            }
        } else {
            Text("Optional. \(voice.rawValue) reads guide answers in a recorded Kokoro voice, at Normal and Slower speed. Your Apple voice reads everything until then, and anything without a recording after.")
                .font(.footnote)
        }
        DownloadControls(manifest: manifest, phase: model.voicePhase(voice), installed: installed,
                         hasUpdate: model.voiceHasUpdate(voice), canResume: model.canResumeVoiceDownload(voice),
                         updateNote: "New recordings are available. KITT keeps using these until the new ones have downloaded and checked out.",
                         deleteLabel: "Delete voice", deleteDisabled: false,
                         download: { model.downloadVoice(voice) }, cancel: { model.cancelVoiceDownload(voice) },
                         delete: { confirmingDelete = true })
    }
}

/// Progress, pause, resume, update and delete for one optional download: the offline model
/// or a guide voice. KITT works the same while any of them downloads.
struct DownloadControls: View {
    let manifest: ModelManifest
    let phase: ModelDownloader.Phase
    let installed: Bool
    let hasUpdate: Bool
    let canResume: Bool
    let updateNote: String
    let deleteLabel: String
    let deleteDisabled: Bool
    let download: () -> Void
    let cancel: () -> Void
    let delete: () -> Void

    var body: some View {
        switch phase {
        case let .downloading(received, total):
            ProgressView(value: Double(received), total: Double(max(total, 1)))
            Text("\(ModelManifest.megabytes(received)) of \(ModelManifest.megabytes(total))")
                .font(.caption2).monospacedDigit()
            Text("You can lower your wrist. The download continues.").font(.caption2).foregroundStyle(.secondary)
            Button("Cancel", action: cancel)
        case .verifying:
            ProgressView()
            Text("Checking the download\u{2026}").font(.caption2)
        case let .paused(received):
            if canResume {
                Text("Paused at \(ModelManifest.megabytes(received)) of \(manifest.sizeLabel).").font(.footnote)
                Button("Resume download", action: download)
            } else {
                Text("Stopped. The watch didn't keep the partial download, so it starts again from the beginning.")
                    .font(.footnote)
                Button("Download again (\(manifest.sizeLabel))", action: download)
            }
        case let .failed(reason):
            Text(reason).font(.footnote).foregroundStyle(.orange)
            Button(canResume ? "Resume download" : "Try again", action: download)
        case .idle:
            if !installed {
                Button("Download (\(manifest.sizeLabel))", action: download)
                Text("Use Wi-Fi or keep your iPhone nearby.").font(.caption2).foregroundStyle(.secondary)
            } else if hasUpdate {
                Text(updateNote).font(.caption2)
                Button("Download update (\(manifest.sizeLabel))", action: download)
            }
        }
        if installed, phase == .idle {
            Button(deleteLabel, role: .destructive, action: delete)
                .disabled(deleteDisabled)
        }
    }
}
