import QuickLook
import SwiftUI

@main
struct KITTPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { PhoneHomeView() }
        }
    }
}

private struct PhoneHomeView: View {
    @State private var sampleURL: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ScannerMark().frame(width: 54)
                    Text("KITT").font(.largeTitle.bold())
                }
                NavigationLink {
                    KokoroSamplesView { name, ext in
                        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { return false }
                        sampleURL = url
                        return true
                    }
                    .quickLookPreview($sampleURL)
                } label: {
                    Label("Hear Kokoro", systemImage: "play.circle")
                }
                .buttonStyle(.borderedProminent)
                Text("KITT runs on your Apple Watch, with or without this phone.")
                Text("If KITT isn't on your watch yet, open the Watch app on this iPhone, scroll to Available Apps, and tap Install next to KITT.")
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }
}
