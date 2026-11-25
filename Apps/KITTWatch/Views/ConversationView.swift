import SwiftUI
import KITTCore

private enum WatchPage: Hashable {
    case guide, topic(String), answer, transcript, more
}

struct ConversationView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [WatchPage] = []
    @State private var draft = ""

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        ScannerMark().frame(width: 33)
                        Text("KITT").font(.title3.bold())
                    }
                    .accessibilityAddTraits(.isHeader)
                    TextField("Ask KITT", text: $draft).onSubmit {
                        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        model.send(draft, via: .unknown)
                        draft = ""
                        path = [.answer]
                    }
                    .disabled(model.isGenerating)
                    NavigationLink("Browse guide", value: WatchPage.guide)
                    if !model.turns.isEmpty || model.isGenerating {
                        NavigationLink("Resume", value: WatchPage.answer)
                    }
                    ActiveHazards { ask($0) }
                    if let status = model.status { Text(status).font(.footnote).foregroundStyle(.orange) }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: WatchPage.more) { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                }
            }
            .stopSpeakingButton(placement: .topBarLeading)
            .navigationDestination(for: WatchPage.self) { page in
                Group {
                    switch page {
                    case .guide:
                        List(model.pack.topics, id: \.self) { topic in
                            NavigationLink(topic, value: WatchPage.topic(topic))
                        }.navigationTitle("Browse guide")
                    case let .topic(topic):
                        List(model.pack.entries(inTopic: topic)) { entry in
                            Button(entry.title) { ask(entry.id) }.disabled(model.isGenerating)
                        }.navigationTitle(topic)
                    case .answer:
                        CurrentAnswerView()
                    case .transcript:
                        TranscriptView()
                    case .more:
                        MoreView(onBrowse: { path.append(.guide) }, onNew: {
                            model.newConversation()
                            path = []
                        })
                    }
                }
                .stopSpeakingButton()
            }
        }
        .onAppear { model.firstAppear() }
    }

    private func ask(_ id: String) {
        model.ask(entryID: id)
        path = [.answer]
    }
}

private struct ActiveHazards: View {
    @EnvironmentObject private var model: AppModel
    let show: (String) -> Void

    var body: some View {
        ForEach(model.activeHazards) { entry in
            VStack(alignment: .leading) {
                Label(entry.hazard?.label ?? entry.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote.bold()).foregroundStyle(.orange)
                HStack {
                    Button("Show") { show(entry.id) }.disabled(model.isGenerating)
                    Button("Clear") { model.clearHazard(entry.id) }
                }
            }
        }
    }
}

private struct CurrentAnswerView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ""

    private var latest: DisplayTurn? {
        model.turns.last {
            if case .assistant = $0.kind { return true }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let stream = model.streamingText {
                    Label("Unverified", systemImage: "sparkles").foregroundStyle(.orange)
                    if stream.isEmpty { ProgressView() } else { Text(stream) }
                    Button("Stop generating") { model.cancelGeneration() }
                } else if let turn = latest, case let .assistant(message) = turn.kind {
                    AnswerContent(turn: turn, message: message, draft: $draft)
                }
                if let status = model.status { Text(status).font(.footnote).foregroundStyle(.orange) }

                ActiveHazards { model.ask(entryID: $0) }
                NavigationLink("Transcript", value: WatchPage.transcript)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Recreate the scroll position only when the answer changes. Speech and
        // incremental tokens must never move the reader's place.
        .id(latest?.id)
        .navigationTitle("Answer")
        // Speech keeps going when Show calculation or the source is opened; every screen
        // shows the stop button while KITT is speaking (stopSpeakingButton).
    }
}

/// The stop square, shown in the top bar of any screen while a reply is being read aloud.
struct StopSpeakingButton: ViewModifier {
    @EnvironmentObject private var model: AppModel
    var placement: ToolbarItemPlacement

    func body(content: Content) -> some View {
        content.toolbar {
            if model.isSpeaking {
                ToolbarItem(placement: placement) {
                    Button { model.stopSpeaking() } label: { Image(systemName: "stop.fill") }
                        .accessibilityLabel("Stop speaking")
                }
            }
        }
    }
}

extension View {
    func stopSpeakingButton(placement: ToolbarItemPlacement = .topBarTrailing) -> some View {
        modifier(StopSpeakingButton(placement: placement))
    }
}

private struct AnswerContent: View {
    @EnvironmentObject private var model: AppModel
    let turn: DisplayTurn
    let message: AssistantMessage
    @Binding var draft: String
    @State private var showingRelated = false

    private var sources: [GuideEntry] {
        message.citations.compactMap { model.pack.entry(forCitation: $0) }
    }

    var body: some View {
        if message.origin == .model {
            Label("Unverified", systemImage: "sparkles").font(.headline).foregroundStyle(.orange)
        }
        if let calculation = turn.calculation {
            let layout = WaterAnswerLayout(text: message.text)
            Text("Water plan").font(.caption).foregroundStyle(.secondary)
            Text(USGallons(calculation.requiredGallons).longLabel)
                .font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text("\(People(calculation.people).label) for \(Days(calculation.days).label)")
            if calculation.storedGallons != nil {
                Text(layout.headline).font(.headline)
            }
            // The default-duration notice and guide notes ("In very hot weather...") stay here.
            ForEach(layout.details, id: \.self) { Text($0).font(.footnote) }
            NavigationLink("Show calculation") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(layout.calculation, id: \.self) { Text($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Calculation")
                .stopSpeakingButton()
            }
        } else {
            let question = sources.first?.hazard?.question
            if message.asksHazardQuestion, let question, message.text.hasSuffix(question) {
                let warning = String(message.text.dropLast(question.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                let lead = warning.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression)?.upperBound ?? warning.endIndex
                Text(String(warning[..<lead])).font(.headline).accessibilityAddTraits(.isHeader)
                Text(question).bold()
                confirmationControls
                let rest = warning[lead...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { Text(rest) }
            } else {
                AnswerText(text: message.text)
                confirmationControls
                if message.isPrecaution { suggestionButtons }
            }
        }
        if message.interrupted { Text("Reply stopped").font(.footnote).foregroundStyle(.orange) }
        if !message.unsupportedNumbers.isEmpty {
            Text("Check the guide: \(message.unsupportedNumbers.joined(separator: ", ")) is not in it.")
                .font(.footnote).foregroundStyle(.orange)
        }
        if message.needsFact != nil {
            NavigationLink("Set household") { HouseholdView().stopSpeakingButton() }
        }
        if message.origin == .app { suggestionButtons }
        TextField("Ask a follow-up", text: $draft).onSubmit {
            model.send(draft, via: .unknown)
            draft = ""
        }
        if message.origin != .app, !message.isPrecaution, !message.suggestions.isEmpty {
            Button("Related topics") { showingRelated = true }
                .sheet(isPresented: $showingRelated) {
                    NavigationStack {
                        List { suggestionButtons }.navigationTitle("Related topics")
                    }
                }
        }
        if model.canAskModel(under: turn) {
            Button("Ask the model anyway") { model.askModelAnyway() }
            Text("Model replies are unverified.").font(.footnote).foregroundStyle(.secondary)
        }
        ForEach(sources) { entry in
            NavigationLink { SourceView(entry: entry).stopSpeakingButton() } label: {
                Label(entry.source.publisher, systemImage: "doc.text").font(.footnote)
            }
        }
    }

    @ViewBuilder private var confirmationControls: some View {
        if let id = model.canConfirmHazard(under: turn) {
            Button("This applies to us") { model.confirmHazard(id) }.tint(.orange)
            if message.asksHazardQuestion, turn.id == model.turns.last?.id {
                Button("Not in use") { model.send(KITTSession.notInUseAnswer, via: .suggestion) }
                Button("Not sure") { model.send(KITTSession.notSureAnswer, via: .suggestion) }
            }
        }
    }

    private var suggestionButtons: some View {
        ForEach(message.suggestions, id: \.self) { id in
            if let entry = model.pack.entry(id) {
                Button(entry.title) {
                    showingRelated = false
                    model.ask(entryID: id)
                }
            }
        }
    }
}

private struct AnswerText: View {
    let text: String
    var body: some View {
        let end = text.range(of: #"[.!?](?=\s|$)|\n"#, options: .regularExpression)?.upperBound ?? text.endIndex
        Text(String(text[..<end])).font(.headline).accessibilityAddTraits(.isHeader)
        let rest = text[end...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { Text(rest) }
    }
}

private struct TranscriptView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        List(model.turns) { turn in
            VStack(alignment: .leading, spacing: 3) {
                switch turn.kind {
                case .user: Text("You").font(.caption.bold())
                case .assistant(let message):
                    Text(message.origin == .model ? "KITT · Unverified" : "KITT")
                        .font(.caption.bold()).foregroundStyle(message.origin == .model ? Color.orange : Color.secondary)
                case .note: EmptyView()
                }
                Text(turn.text)
            }
        }
        .navigationTitle("Transcript")
    }
}
