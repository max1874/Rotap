import SwiftUI

/// While recording nothing here is observed per tick: the clock and status text are 1 Hz timelines, and the
/// meter is a layer-backed view that pulls peaks from the recorder on its own display link.
struct LiveRecordingView: View {
    let session: RecorderModel.Session
    @Environment(RecorderModel.self) private var recorder

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            HStack(spacing: 8) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.record)
                if let source = session.source {
                    SourceIcon(source: source)
                    Text(source.name)
                }
                if let microphone = session.microphone {
                    if session.source != nil { Text("+").foregroundStyle(.secondary) }
                    Image(systemName: "mic.fill")
                    Text(microphone.name)
                }
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)

            TimelineView(.periodic(from: session.startedAt, by: 1)) { context in
                Text(Self.clock(context.date.timeIntervalSince(session.startedAt)))
                    .font(.system(size: 72, weight: .light, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.top, 28)

            LiveWaveformView(peaks: recorder.livePeaks)
                .frame(height: 120)
                .padding(.top, 20)

            TimelineView(.periodic(from: session.startedAt, by: 1)) { _ in
                Text(recorder.hasHeardSound ? "正在录音"
                     : session.source == nil ? "等待声音…" : "等待声音… 开始播放后波形就会出现")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            Spacer(minLength: 24)

            Button(action: recorder.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(Color.recordGlassTint)
            .help("停止录音 (⌘R)")
            .padding(.bottom, 32)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
