import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class RecorderModel {
    struct Session: Equatable {
        let url: URL
        /// The recorded app/system source, when system audio is part of the recording.
        let source: AudioSource?
        /// The recorded input device, when the microphone is part of the recording.
        let microphone: InputDevice?
        let startedAt: Date

        /// Used for the file name and the recording's title.
        var label: String {
            switch (source, microphone) {
            case let (source?, nil): source.label
            case let (source?, _?): String(localized: "\(source.label) + Microphone")
            default: String(localized: "Microphone")
            }
        }
    }

    private(set) var session: Session?
    private(set) var sources: [AudioSource] = [.system]
    private(set) var microphones: [InputDevice] = []
    private(set) var defaultMicrophone: InputDevice?
    /// Set when a recording finishes, so the library can select it.
    private(set) var finishedRecording: URL?
    var errorMessage: String?
    var selectedSourceID = AudioSource.systemID

    var isRecording: Bool { session != nil }
    var selectedSource: AudioSource { sources.first { $0.id == selectedSourceID } ?? .system }
    /// The chosen input, falling back to the system default when the chosen one is gone.
    var selectedMicrophone: InputDevice? {
        microphones.first { $0.uid == preferences.microphoneUID } ?? defaultMicrophone
    }

    private let preferences: Preferences
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private var observers: [AnyObject] = []
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var starting = false

    init(preferences: Preferences) {
        self.preferences = preferences
        recorder.onFailure = { [weak self] error in
            self?.stop()
            self?.errorMessage = String(localized: "Couldn’t write the recording: \(error.localizedDescription)")
        }
        refreshSources()
        refreshMicrophones()
        observers.append(AudioSource.observeChanges { [weak self] in self?.refreshSources() })
        observers += InputDevice.observeChanges { [weak self] in self?.refreshMicrophones() }
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

    func refreshMicrophones() {
        microphones = InputDevice.all()
        defaultMicrophone = InputDevice.defaultDevice()
    }

    func toggle() {
        isRecording ? stop() : start()
    }

    func start() {
        guard !isRecording, !starting else { return }
        guard preferences.captureMode.includesMicrophone else { return begin() }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            begin()
        case .notDetermined:
            starting = true
            Task {
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                starting = false
                if granted { begin() } else { reportMicrophoneDenied() }
            }
        default:
            reportMicrophoneDenied()
        }
    }

    private func begin() {
        refreshSources()
        let mode = preferences.captureMode
        let source = mode.includesSystem ? selectedSource : nil
        var microphone: InputDevice?
        if mode.includesMicrophone {
            refreshMicrophones()
            guard let selected = selectedMicrophone else {
                errorMessage = String(localized: "No microphone is available.")
                return
            }
            microphone = selected
        }

        do {
            let directory = preferences.directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let label = Session(url: directory, source: source, microphone: microphone, startedAt: .now).label
            let url = Recording.newURL(in: directory, label: label, format: preferences.format)
            try recorder.start(
                CaptureConfiguration(system: source, microphoneUID: microphone?.uid),
                url: url,
                format: preferences.format
            )
            session = Session(url: url, source: source, microphone: microphone, startedAt: .now)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reportMicrophoneDenied() {
        errorMessage = String(localized: "Rotap doesn’t have access to the microphone. Allow Rotap in System Settings › Privacy & Security › Microphone, or switch to System Audio Only.")
    }

    func stop() {
        guard let session else { return }
        let stats = recorder.stop()
        self.session = nil
        refreshSources()
        finishedRecording = session.url
        if stats.droppedFrames > 0 {
            let seconds = Double(stats.droppedFrames) / stats.sampleRate
            errorMessage = String(localized: "The disk couldn’t keep up; about \(seconds.formatted(.number.precision(.fractionLength(1)))) seconds of audio were lost.")
        }
    }
}
