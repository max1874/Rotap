import AppKit
import Observation

@MainActor
@Observable
final class RecorderModel {
    struct Session: Equatable {
        let url: URL
        let source: AudioSource
        let startedAt: Date
    }

    private(set) var session: Session?
    private(set) var sources: [AudioSource] = [.system]
    /// Set when a recording finishes, so the library can select it.
    private(set) var finishedRecording: URL?
    var errorMessage: String?
    var selectedSourceID = AudioSource.systemID

    var isRecording: Bool { session != nil }
    var selectedSource: AudioSource { sources.first { $0.id == selectedSourceID } ?? .system }

    private let preferences: Preferences
    @ObservationIgnored private let recorder = SystemAudioRecorder()
    @ObservationIgnored private var processObserver: AnyObject?
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?

    init(preferences: Preferences) {
        self.preferences = preferences
        recorder.onFailure = { [weak self] error in
            self?.stop()
            self?.errorMessage = "写入失败：\(error.localizedDescription)"
        }
        refreshSources()
        processObserver = AudioSource.observeChanges { [weak self] in self?.refreshSources() }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Closing the file finalizes the container; never leave a half-written recording behind.
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    // MARK: Live values, sampled by timeline views rather than observed, so recording never invalidates the view graph.

    var hasHeardSound: Bool { recorder.stats.heardSound }

    func livePeaks(_ count: Int) -> LivePeaks {
        recorder.recentPeaks(count)
    }

    // MARK: Control

    func refreshSources() {
        guard !isRecording else { return }
        sources = [.system] + AudioSource.available()
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording else { return }
        refreshSources()
        let source = selectedSource
        do {
            let directory = preferences.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = Recording.newURL(in: directory, source: source, format: preferences.format)
            try recorder.start(source: source, url: url, format: preferences.format)
            session = Session(url: url, source: source, startedAt: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard let session else { return }
        let stats = recorder.stop()
        self.session = nil
        refreshSources()
        finishedRecording = session.url
        if stats.droppedFrames > 0 {
            let seconds = Double(stats.droppedFrames) / stats.sampleRate
            errorMessage = String(format: "磁盘写入跟不上，丢失了约 %.1f 秒音频。", seconds)
        }
    }
}
