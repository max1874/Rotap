import SwiftUI

struct RotapApp: App {
    @State private var preferences: Preferences
    @State private var recorder: RecorderModel
    @State private var library = RecordingLibrary()
    @State private var player = PlaybackModel()

    init() {
        let preferences = Preferences()
        _preferences = State(initialValue: preferences)
        _recorder = State(initialValue: RecorderModel(preferences: preferences))
    }

    var body: some Scene {
        Window("Rotap", id: "main") {
            ContentView()
                .environment(preferences)
                .environment(recorder)
                .environment(library)
                .environment(player)
        }
        .defaultSize(width: 980, height: 620)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Recording") {
                Button(recorder.isRecording ? "Stop Recording" : "Start Recording", action: recorder.toggle)
                    .keyboardShortcut("r")
                Divider()
                Button(player.isPlaying ? "Pause" : "Play", action: player.toggle)
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(player.url == nil || recorder.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environment(preferences)
                .environment(recorder)
        }
    }
}
