import SwiftUI

struct SettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences

        Form {
            Section("录音格式") {
                Picker("格式", selection: $preferences.format) {
                    Text("M4A · AAC，体积小").tag(OutputFormat.m4a)
                    Text("WAV · 24-bit 无损").tag(OutputFormat.wav)
                }
                .pickerStyle(.radioGroup)
            }

            Section("保存位置") {
                LabeledContent("文件夹") {
                    Text(preferences.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("更改…", action: chooseDirectory)
                    Button("在 Finder 中显示") { NSWorkspace.shared.open(preferences.directory) }
                    Spacer()
                    if preferences.directory != Preferences.defaultDirectory {
                        Button("恢复默认") { preferences.directory = Preferences.defaultDirectory }
                    }
                }
            }

            Section {
                Text("第一次录音时，macOS 会询问是否允许 Rotap 录制其他 App 的音频。如果录下来全是静音，请在系统设置里打开 Rotap 的权限。")
                    .foregroundStyle(.secondary)
                Button("打开隐私与安全性设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                }
            } header: {
                Text("权限")
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
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            preferences.directory = url
        }
    }
}
