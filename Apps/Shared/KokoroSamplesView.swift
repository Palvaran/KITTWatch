import SwiftUI

struct KokoroSamplesView: View {
    let play: (String, String) -> Bool
    @State private var failedSample: String?

    var body: some View {
        List {
            Section("Voice sample") {
                sampleRows(["Michael", "Heart", "Fenrir"], prefix: "Kokoro")
            }
            Section("Heat-stroke instruction") {
                sampleRows(["Michael", "Heart"], prefix: "Kokoro-Heat", fileExtension: "mp3")
            }
            Section("Water total") {
                sampleRows(["Michael", "Heart"], prefix: "Kokoro-Water", fileExtension: "mp3")
            }
        }
        .navigationTitle("Hear Kokoro")
    }

    private func sampleRows(_ voices: [String], prefix: String, fileExtension: String = "wav") -> some View {
        ForEach(voices, id: \.self) { voice in
            let resource = "\(prefix)-\(voice)"
            Button {
                failedSample = play(resource, fileExtension) ? nil : resource
            } label: {
                Label(voice, systemImage: "play.circle")
            }
            if failedSample == resource { Text("Couldn’t play the sample.").font(.caption2) }
        }
    }
}
