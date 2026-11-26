import SwiftUI

@main
struct KITTWatchApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ConversationView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(to: phase)
        }
        // The offline model and the voice packs download in background sessions. When one
        // finishes while KITT is suspended, the system wakes KITT here to install it.
        .backgroundTask(.urlSession(ModelDownloader.shared.sessionID)) {
            await ModelDownloader.shared.handleBackgroundEvents()
        }
        .backgroundTask(.urlSession(ModelDownloader.heartVoice.sessionID)) {
            await ModelDownloader.heartVoice.handleBackgroundEvents()
        }
        .backgroundTask(.urlSession(ModelDownloader.michaelVoice.sessionID)) {
            await ModelDownloader.michaelVoice.handleBackgroundEvents()
        }
    }
}
