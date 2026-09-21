import Foundation

/// `Rotap --record <seconds> [--out <file>] [--app <bundle id>] [--format m4a|wav]`
/// (`Rotap --list-sources` prints the ids accepted by `--app`.)
/// Records without UI and exits. Launch through `open -W Rotap.app --args ...` so the
/// audio-capture permission is attributed to Rotap rather than the terminal.
struct HeadlessRecording {
    let seconds: Double
    let output: URL?
    let appBundleID: String?
    let format: OutputFormat

    init?(arguments: [String]) {
        func value(_ flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        guard let seconds = value("--record").flatMap(Double.init) else { return nil }
        self.seconds = seconds
        output = value("--out").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        appBundleID = value("--app")
        format = value("--format").flatMap(OutputFormat.init)
            ?? output.flatMap { OutputFormat(rawValue: $0.pathExtension.lowercased()) }
            ?? .m4a
    }

    @MainActor
    func run() -> Int32 {
        var source = AudioSource.system
        if let appBundleID {
            guard let match = AudioSource.available().first(where: { $0.id == appBundleID }) else {
                log("未找到正在使用音频的 App：\(appBundleID)")
                return 2
            }
            source = match
        }

        let url = output ?? {
            let directory = Preferences.defaultDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return Recording.newURL(in: directory, source: source, format: format)
        }()

        let recorder = SystemAudioRecorder()
        var failure: Error?
        recorder.onFailure = { failure = $0 }
        do {
            try recorder.start(source: source, url: url, format: format)
        } catch {
            log("录音失败：\(error.localizedDescription)")
            return 1
        }

        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let stats = recorder.stop()

        if let failure {
            log("写入失败：\(failure.localizedDescription)")
            return 1
        }
        let envelope = Waveform.load(from: url) ?? []
        log(String(
            format: "%@  source=%@  duration=%.2fs  dropped=%lld  peak=%.3f  waveform=%d",
            url.path, source.label, stats.duration, stats.droppedFrames, envelope.max() ?? 0, envelope.count
        ))
        return 0
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
