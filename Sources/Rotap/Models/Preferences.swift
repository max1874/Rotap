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

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0].appendingPathComponent("Rotap", isDirectory: true)
    }

    init() {
        let defaults = UserDefaults.standard
        format = defaults.string(forKey: "format").flatMap(OutputFormat.init) ?? .m4a
        directory = defaults.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultDirectory
    }
}
