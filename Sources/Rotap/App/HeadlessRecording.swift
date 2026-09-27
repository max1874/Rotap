import Foundation

/// `Rotap --record <seconds> [--out <file>] [--mode system|microphone|both] [--app <bundle id>]
///  [--mic <device uid>] [--format m4a|wav]`
/// (`Rotap --list-sources` prints the ids accepted by `--app`.)
/// Records without UI and exits. Launch through `open -W Rotap.app --args ...` so the
/// audio-capture permission is attributed to Rotap rather than the terminal.
struct HeadlessRecording {
    let seconds: Double
    let output: URL?
    let mode: CaptureMode
    let appBundleID: String?
    let microphoneUID: String?
    let format: OutputFormat

    init?(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let seconds = value("--record").flatMap(Double.init) else { return nil }
        self.seconds = seconds
        output = value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        mode = value("--mode").flatMap(CaptureMode.init) ?? .system
        appBundleID = value("--app")
        microphoneUID = value("--mic")
        format = value("--format").flatMap(OutputFormat.init)
            ?? output.flatMap { OutputFormat(rawValue: $0.pathExtension.lowercased()) }
            ?? .m4a
    }

    @MainActor
    func run() -> Int32 {
        var source: AudioSource?
        if mode.includesSystem {
            source = .system
            if let appBundleID {
                guard let match = AudioSource.available().first(where: { $0.id == appBundleID }) else {
                    log("No app using audio matches \(appBundleID)")
                    return 2
                }
                source = match
            }
        }
        var microphone: String?
        if mode.includesMicrophone {
            guard let uid = microphoneUID ?? InputDevice.defaultDevice()?.uid else {
                log("No microphone is available")
                return 2
            }
            microphone = uid
        }

        let label = switch (source, microphone) {
        case let (source?, nil): source.label
        case let (source?, _?): String(localized: "\(source.label) + Microphone")
        default: String(localized: "Microphone")
        }
        let url = output ?? {
            let directory = Preferences.defaultDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return Recording.newURL(in: directory, label: label, format: format)
        }()

        let recorder = AudioRecorder()
        var failure: Error?
        recorder.onFailure = { failure = $0 }
        do {
            try recorder.start(CaptureConfiguration(system: source, microphoneUID: microphone), url: url, format: format)
        } catch {
            log("Recording failed: \(error.localizedDescription)")
            return 1
        }

        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let stats = recorder.stop()

        if let failure {
            log("Writing failed: \(failure.localizedDescription)")
            return 1
        }
        let envelope = Waveform.load(from: url) ?? []
        log(String(
            format: "%@  source=%@  duration=%.2fs  dropped=%lld  peak=%.3f  waveform=%d",
            url.path, label, stats.duration, stats.droppedFrames, envelope.max() ?? 0, envelope.count
        ))
        return 0
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
