import Foundation
import KITTCore

/// Who reads guide replies aloud. Heart and Michael are recorded Kokoro voices, each an
/// optional download (More › Voice). The Apple voice reads everything they have no
/// recording for, model replies included, and everything when no voice pack is installed.
enum GuideVoice: String, CaseIterable {
    case system = "Apple voice"
    case heart = "Heart"
    case michael = "Michael"

    /// The voices that come as downloadable recordings.
    static let recorded: [GuideVoice] = [.heart, .michael]

    /// Downloads and stores this voice's pack. nil for the Apple voice.
    var downloader: ModelDownloader? {
        switch self {
        case .system: return nil
        case .heart: return .heartVoice
        case .michael: return .michaelVoice
        }
    }
}
