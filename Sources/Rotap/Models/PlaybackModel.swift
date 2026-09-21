import AVFoundation
import Observation

@MainActor
@Observable
final class PlaybackModel: NSObject, AVAudioPlayerDelegate {
    private(set) var url: URL?
    private(set) var isPlaying = false
    private(set) var duration: TimeInterval = 0
    /// Position while paused. While playing, views sample `currentTime` from a timeline instead,
    /// so playback does not invalidate the view graph on every tick.
    private(set) var pausedPosition: TimeInterval = 0

    @ObservationIgnored private var player: AVAudioPlayer?

    var currentTime: TimeInterval { isPlaying ? (player?.currentTime ?? 0) : pausedPosition }

    func load(_ url: URL?) {
        guard url != self.url else { return }
        player?.stop()
        player = nil
        isPlaying = false
        pausedPosition = 0
        duration = 0
        self.url = url
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else { return }
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            pausedPosition = player.currentTime
            isPlaying = false
        } else {
            if pausedPosition >= duration - 0.05 { pausedPosition = 0 }
            player.currentTime = pausedPosition
            isPlaying = player.play()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        let clamped = min(max(0, time), duration)
        player.currentTime = clamped
        pausedPosition = clamped
    }

    func skip(by delta: TimeInterval) {
        seek(to: currentTime + delta)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            pausedPosition = duration
        }
    }
}
