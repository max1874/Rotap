import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("Recording Format") {
                Picker("Format", selection: $preferences.format) {
                    Text("M4A · AAC, smaller files").tag(OutputFormat.m4a)
                    Text("WAV · 24-bit lossless").tag(OutputFormat.wav)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Save Location") {
                LabeledContent("Folder") {
                    Text(preferences.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Change…", action: chooseDirectory)
                    Button("Show in Finder") { NSWorkspace.shared.open(preferences.directory) }
                    Spacer()
                    if preferences.directory != Preferences.defaultDirectory {
                        Button("Restore Default") { preferences.directory = Preferences.defaultDirectory }
                    }
                }
            }

            Section("Language") {
                Picker("Language", selection: $preferences.language) {
                    Text("Follow System").tag(AppLanguage.system)
                    // Each language is named in itself, so it can be found whatever the current one is.
                    Text(verbatim: "English").tag(AppLanguage.english)
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                }
                if preferences.needsRelaunchForLanguage {
                    HStack {
                        Text("Restart Rotap to switch the language.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppLanguage.relaunch() }
                            .disabled(recorder.isRecording)
                    }
                }
            }

            Section {
                Text("The first time you record, macOS asks whether Rotap may record other apps’ audio, and the microphone when you use it. If a recording is silent, allow Rotap in System Settings.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy & Security Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.directory
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            preferences.directory = url
        }
    }
}
