import Accelerate
import AVFoundation

enum Waveform {
    /// Peaks per second, both for the live meter and for the envelope stored with each file.
    static let peaksPerSecond = 20.0
    /// Extended attribute holding the envelope, so it follows the file through renames, copies and the Trash.
    static let attributeName = "app.rotap.waveform"

    /// Maps a linear peak to 0…1 on a -50…0 dB scale, so quiet passages stay visible.
    static func normalized(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(peak) + 50) / 50))
    }

    static func store(_ peaks: [Float], on url: URL) {
        let bytes = peaks.map { UInt8(($0 * 255).rounded()) }
        _ = bytes.withUnsafeBytes { raw in
            setxattr(url.path, attributeName, raw.baseAddress, raw.count, 0, 0)
        }
    }

    static func load(from url: URL) -> [Float]? {
        let size = getxattr(url.path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, attributeName, &bytes, size, 0, 0) == size else { return nil }
        return bytes.map { Float($0) / 255 }
    }

    /// Max-pools `peaks` down to at most `count` values, so short transients survive.
    static func downsample(_ peaks: [Float], to count: Int) -> [Float] {
        guard peaks.count > count, count > 0 else { return peaks }
        return (0..<count).map { bucket in
            let start = bucket * peaks.count / count
            let end = max(start + 1, (bucket + 1) * peaks.count / count)
            return peaks[start..<end].max() ?? 0
        }
    }
}

/// Folds sample blocks into fixed-duration peaks.
struct WaveformAccumulator {
    let framesPerPeak: Int
    private(set) var peaks: [Float] = []
    private var currentPeak: Float = 0
    private var framesInPeak = 0

    init(sampleRate: Double) {
        framesPerPeak = max(1, Int(sampleRate / Waveform.peaksPerSecond))
    }

    /// `channels` are per-channel pointers (deinterleaved, stride 1) or one pointer to interleaved data with `stride == channelCount`.
    mutating func add(_ channels: [UnsafePointer<Float>], stride: Int, frames: Int) {
        var offset = 0
        while offset < frames {
            let take = min(framesPerPeak - framesInPeak, frames - offset)
            for pointer in channels {
                var peak: Float = 0
                let count = stride == 1 ? take : take * stride
                vDSP_maxmgv(pointer + offset * stride, 1, &peak, vDSP_Length(count))
                currentPeak = max(currentPeak, peak)
            }
            framesInPeak += take
            offset += take
            if framesInPeak == framesPerPeak { flush() }
        }
    }

    mutating func finish() -> [Float] {
        if framesInPeak > 0 { flush() }
        return peaks
    }

    private mutating func flush() {
        peaks.append(Waveform.normalized(currentPeak))
        currentPeak = 0
        framesInPeak = 0
    }
}

/// Serves per-file envelopes: from the stored attribute when Rotap recorded the file, otherwise analyzed once and stored.
actor WaveformStore {
    static let shared = WaveformStore()

    private struct Key: Hashable { let url: URL; let modified: Date }
    private var cache: [Key: [Float]] = [:]

    func peaks(for url: URL, maxCount: Int = 1200) async -> [Float] {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let key = Key(url: url, modified: modified)
        if let cached = cache[key] { return cached }
        let peaks = await Task.detached(priority: .userInitiated) {
            let full = Waveform.load(from: url) ?? Self.analyze(url: url)
            return Waveform.downsample(full, to: maxCount)
        }.value
        cache[key] = peaks
        return peaks
    }

    private static func analyze(url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return [] }
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
              let data = buffer.floatChannelData
        else { return [] }

        var accumulator = WaveformAccumulator(sampleRate: file.processingFormat.sampleRate)
        let channels = (0..<Int(buffer.format.channelCount)).map { UnsafePointer(data[$0]) }
        while file.framePosition < file.length {
            guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
            accumulator.add(channels, stride: buffer.stride, frames: Int(buffer.frameLength))
        }
        let peaks = accumulator.finish()
        Waveform.store(peaks, on: url)
        return peaks
    }
}
