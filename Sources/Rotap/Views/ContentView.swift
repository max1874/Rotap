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
            Button("好") {}
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
    @Environment(RecorderModel.self) private var recorder

    var body: some ToolbarContent {
        @Bindable var recorder = recorder

        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("来源", selection: $recorder.selectedSourceID) {
                    ForEach(recorder.sources) { source in
                        Label {
                            Text(source.isPlaying ? "\(source.name)（正在发声）" : source.name)
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
            .disabled(recorder.isRecording)
            .help("选择要录制的声音来源")
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button(action: recorder.toggle) {
                Label(recorder.isRecording ? "停止" : "录音",
                      systemImage: recorder.isRecording ? "stop.fill" : "record.circle")
                    .contentTransition(.symbolEffect(.replace))
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .tint(Color.recordGlassTint)
            .help(recorder.isRecording ? "停止录音 (⌘R)" : "开始录音 (⌘R)")
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
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        ContentUnavailableView {
            Label("录下 Mac 正在播放的声音", systemImage: "waveform")
        } description: {
            Text("选择来源后开始录音。Rotap 只在旁边聆听，不改变你的扬声器或耳机输出。")
        } actions: {
            Button {
                recorder.start()
            } label: {
                Label("开始录音", systemImage: "record.circle")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(Color.recordGlassTint)
            .controlSize(.large)
        }
    }
}
