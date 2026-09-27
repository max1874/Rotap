import AppKit

/// The app's own interface language, independent of the system's.
///
/// Stored the way macOS stores a per-app language (System Settings › General › Language & Region):
/// `AppleLanguages` in the app's defaults domain. Bundle lookup, menus, system dialogs and date formats all
/// read it at launch, so a change takes effect after a relaunch — never half-translated.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// The current choice, read from the app's own defaults domain (not the global one).
    static var saved: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        guard let first = (domain?["AppleLanguages"] as? [String])?.first else { return .system }
        return first.hasPrefix("zh") ? .simplifiedChinese : .english
    }

    func save() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// Quits and reopens Rotap. A helper shell waits for this process to exit so the new copy never overlaps it.
    @MainActor
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$0\"",
            Bundle.main.bundleURL.path,
        ]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}
