import SwiftUI

struct PlayerView: View {
    let recording: Recording
    @Binding var selection: URL?

    @Environment(RecordingLibrary.self) private var library
    @Environment(PlaybackModel.self) private var player

    @State private var title = ""
    @State private var peaks: [Float]?
    @State private var renameError: String?
    @FocusState private var editingTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(.title, weight: .semibold))
                .focused($editingTitle)
                .onSubmit(commitRename)
                .onChange(of: editingTitle) { _, editing in if !editing { commitRename() } }

            metadata
                .padding(.top, 6)

            Spacer(minLength: 28)

            PlaybackWaveformView(
                peaks: peaks ?? [],
                isPlaying: player.isPlaying,
                pausedPosition: player.pausedPosition,
                progress: { player.duration > 0 ? player.currentTime / player.duration : 0 },
                seek: { player.seek(to: $0 * player.duration) }
            )
            .frame(height: 150)
            .opacity(peaks == nil ? 0.4 : 1)
            .animation(.easeOut(duration: 0.25), value: peaks == nil)

            TimelineView(.animation(minimumInterval: 0.5, paused: !player.isPlaying)) { _ in
                HStack {
                    Text(Self.time(player.currentTime))
                    Spacer()
                    Text("-" + Self.time(max(0, player.duration - player.currentTime)))
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.top, 10)

            Spacer(minLength: 28)
        }
        .padding(.horizontal, 44)
        .padding(.top, 32)
        .safeAreaInset(edge: .bottom) {
            PlayerControls()
                .padding(.bottom, 28)
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("Show in Finder", systemImage: "folder") { library.reveal(recording) }
                ShareLink(item: recording.url)
            }
        }
        .task(id: recording.url) {
            title = recording.title
            peaks = await WaveformStore.shared.peaks(for: recording.url)
        }
        .alert("Couldn’t Rename", isPresented: Binding(get: { renameError != nil }, set: { if !$0 { renameError = nil } })) {
            Button("OK") { title = recording.title }
        } message: {
            Text(renameError ?? "")
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(recording.date, format: .dateTime.year().month().day().hour().minute())
            if let duration = recording.duration {
                Text(verbatim: "·")
                Text(Self.time(duration))
            }
            Text(verbatim: "·")
            Text(recording.format)
            Text(verbatim: "·")
            Text(recording.size, format: .byteCount(style: .file))
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func commitRename() {
        guard title != recording.title else { return }
        do {
            selection = try library.rename(recording, to: title)
        } catch {
            renameError = error.localizedDescription
        }
    }

    static func time(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PlayerControls: View {
    @Environment(PlaybackModel.self) private var player

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                Button { player.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .help("Back 15 Seconds")

                Button(action: player.toggle) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 56, height: 56)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.glassProminent)
                .help(player.isPlaying ? "Pause" : "Play")

                Button { player.skip(by: 15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.glass)
                .help("Forward 15 Seconds")
            }
            .buttonBorderShape(.circle)
        }
        .frame(maxWidth: .infinity)
    }
}

