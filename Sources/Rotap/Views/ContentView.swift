import SwiftUI

struct ContentView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(RecorderModel.self) private var recorder
    @Environment(RecordingLibrary.self) private var library
    @Environment(PlaybackModel.self) private var player

    @State private var selection: URL?

    private var selectedRecording: Recording? {
        library.recordings.first { $0.url == selection }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 380)
        } detail: {
            detail
                .animation(.smooth(duration: 0.35), value: recorder.isRecording)
        }
        .frame(minWidth: 720, minHeight: 460)
        .toolbar { RecordToolbar() }
        .task(id: preferences.directory) { library.watch(preferences.directory) }
        .onChange(of: recorder.session?.url) { _, url in
            library.activeRecording = url
            if url != nil, player.isPlaying { player.toggle() }
        }
        .onChange(of: recorder.finishedRecording) { _, url in
            if let url { selection = url }
        }
        .onChange(of: selection) { _, url in player.load(url) }
        .alert("Rotap", isPresented: errorBinding) {
            Button("OK") {}
        } message: {
            Text(recorder.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let session = recorder.session {
            LiveRecordingView(session: session)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        } else if let recording = selectedRecording {
            PlayerView(recording: recording, selection: $selection)
                .id(recording.url)
                .transition(.opacity)
        } else {
            EmptyStateView()
                .transition(.opacity)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { recorder.errorMessage != nil },
            set: { if !$0 { recorder.errorMessage = nil } }
        )
    }
}

struct RecordToolbar: ToolbarContent {
    @Environment(Preferences.self) private var preferences
    @Environment(RecorderModel.self) private var recorder

    var body: some ToolbarContent {
        @Bindable var preferences = preferences
        @Bindable var recorder = recorder

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Capture", selection: $preferences.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)

                Picker("Microphone", selection: $preferences.microphoneUID) {
                    Group {
                        if let device = recorder.defaultMicrophone {
                            Text("System Default (\(device.name))")
                        } else {
                            Text("System Default")
                        }
                    }
                    .tag("")
                    ForEach(recorder.microphones) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .pickerStyle(.inline)
                .disabled(!preferences.captureMode.includesMicrophone)
            } label: {
                Label("Microphone", systemImage: preferences.captureMode.includesMicrophone ? "mic.fill" : "mic.slash")
                    .labelStyle(.iconOnly)
            }
            .disabled(recorder.isRecording)
            .help("Record system audio, the microphone, or both")
        }

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Source", selection: $recorder.selectedSourceID) {
                    ForEach(recorder.sources) { source in
                        Label {
                            source.isPlaying ? Text("\(source.name) (playing)") : Text(verbatim: source.name)
                        } icon: {
                            SourceIcon(source: source)
                        }
                        .tag(source.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label {
                    Text(recorder.selectedSource.name)
                } icon: {
                    SourceIcon(source: recorder.selectedSource)
                }
                .labelStyle(.titleAndIcon)
            }
            .disabled(recorder.isRecording || !preferences.captureMode.includesSystem)
            .help("Choose what to record")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button(action: recorder.toggle) {
                Label(recorder.isRecording ? "Stop" : "Record",
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .tint(Color.recordGlassTint)
            .help(recorder.isRecording ? "Stop Recording (⌘R)" : "Start Recording (⌘R)")
        }
    }
}

struct SourceIcon: View {
    let source: AudioSource

    var body: some View {
        if let path = source.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: source.isSystem ? "macbook" : "app.dashed")
        }
    }
}

struct EmptyStateView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        ContentUnavailableView {
            switch preferences.captureMode {
            case .system: Label("Record What Your Mac Plays", systemImage: "waveform")
            case .microphone: Label("Record with the Microphone", systemImage: "mic")
            case .both: Label("Record Your Mac and the Microphone", systemImage: "waveform.and.mic")
            }
        } description: {
            switch preferences.captureMode {
            case .system: Text("Pick a source and start recording. Rotap just listens in and never changes your speaker or headphone output.")
            case .microphone: Text("To use a different microphone, pick it from the microphone menu in the toolbar.")
            case .both: Text("Your voice and what your Mac plays are mixed into one file. Rotap never changes your speaker or headphone output.")
            }
        } actions: {
            Button {
                recorder.start()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.recordGlassTint)
            .controlSize(.large)
        }
    }
}
