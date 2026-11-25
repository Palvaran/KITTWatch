import SwiftUI

/// The iPhone app exists to carry KITT to the watch. KITT runs on the watch on its own;
/// this app only gives a development build a reliable way there: Xcode installs this app
/// over the USB cable, and the iPhone then installs the embedded watch app the way any
/// App Store watch app arrives. The phone relay (milestone 3) will live here later.
@main
struct KITTPhoneApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    ScannerMark().frame(width: 54)
                    Text("KITT").font(.largeTitle.bold())
                }
                Text("KITT runs on your Apple Watch, with or without this phone.")
                Text("If KITT isn't on your watch yet, open the Watch app on this iPhone, scroll to Available Apps, and tap Install next to KITT.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding()
        }
    }
}
