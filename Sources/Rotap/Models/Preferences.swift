import Foundation
import Observation

@MainActor
@Observable
final class Preferences {
    var format: OutputFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: "format") }
    }
    var directory: URL {
        didSet { UserDefaults.standard.set(directory.path, forKey: "outputDirectory") }
    }
    var captureMode: CaptureMode {
        didSet { UserDefaults.standard.set(captureMode.rawValue, forKey: "captureMode") }
    }
    var language: AppLanguage {
        didSet { language.save() }
    }
    /// The language this process launched with; switching takes a relaunch.
    let launchLanguage = AppLanguage.saved
    var needsRelaunchForLanguage: Bool { language != launchLanguage }
    /// Empty means "follow the system default input".
    var microphoneUID: String {
        didSet { UserDefaults.standard.set(microphoneUID, forKey: "microphoneUID") }
    }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Rotap", isDirectory: true)
    }

    init() {
        let defaults = UserDefaults.standard
        format = defaults.string(forKey: "format").flatMap(OutputFormat.init) ?? .m4a
        directory = defaults.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultDirectory
        captureMode = defaults.string(forKey: "captureMode").flatMap(CaptureMode.init) ?? .system
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        language = launchLanguage
    }
}
