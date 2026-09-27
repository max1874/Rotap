import Accelerate
import AVFoundation
import CoreAudio
import Synchronization

enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case m4a, wav

    var id: String { rawValue }

    func settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        switch self {
        case .m4a:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: min(sampleRate, 48_000),
                AVNumberOfChannelsKey: channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        }
    }
}

struct LivePeaks: Sendable {
    /// Newest peaks, oldest first.
    var levels: [Float]
    /// Peaks produced since recording started; the last element of `levels` has index `total - 1`.
    var total: Int
}

/// What to capture: system (or one app's) audio through a process tap, a microphone, or both mixed.
struct CaptureConfiguration: Sendable {
    var system: AudioSource?
    var microphoneUID: String?
}

/// Records through one private aggregate device holding the process tap and/or the microphone, so both share
/// a clock and arrive sample-aligned in a single IO callback.
///
/// Pipeline: HAL real-time IO thread (mix to stereo) → lock-free ring buffer → writer thread (encode, write,
/// waveform). Nothing on the IO thread allocates, locks or touches the disk.
/// Playback routing is untouched: no virtual device, the tap just listens alongside the real output.
final class AudioRecorder: @unchecked Sendable {
    struct Stats: Sendable {
        var frames: Int64
        var droppedFrames: Int64
        var sampleRate: Double
        /// Whether anything above digital silence has been captured.
        var heardSound: Bool
        var duration: TimeInterval { sampleRate > 0 ? Double(frames) / sampleRate : 0 }
    }

    /// Called on the main queue if encoding or writing fails mid-recording.
    var onFailure: (@MainActor @Sendable (Error) -> Void)?

    private var tapID = AudioObjectID.unknown
    private var aggregateID = AudioObjectID.unknown
    private var ioProcID: AudioDeviceIOProcID?
    private var keepAlive: (device: AudioObjectID, procID: AudioDeviceIOProcID)?
    private var io: IOState?
    private var writer: Writer?

    deinit { stop() }

    var stats: Stats {
        guard let io else { return Stats(frames: 0, droppedFrames: 0, sampleRate: 0, heardSound: false) }
        return Stats(
            frames: io.frames.load(ordering: .relaxed),
            droppedFrames: io.droppedFrames.load(ordering: .relaxed),
            sampleRate: io.sampleRate,
            heardSound: writer?.heardSound.load(ordering: .relaxed) ?? false
        )
    }

    /// The most recent `count` waveform peaks (oldest first) plus how many peaks exist in total, for the live meter.
    func recentPeaks(_ count: Int) -> LivePeaks {
        writer?.recentPeaks(count) ?? LivePeaks(levels: [], total: 0)
    }

    func start(_ configuration: CaptureConfiguration, url: URL, format: OutputFormat) throws {
        stop()
        do {
            var tapRate: Double?
            if let source = configuration.system {
                try createTap(for: source)
                tapRate = try readTapFormat().mSampleRate
                startOutputKeepAlive()
            }
            try createAggregateDevice(includeTap: tapID != .unknown, microphoneUID: configuration.microphoneUID)

            // The aggregate runs at its main device's rate (the microphone when present); the tap is resampled to it.
            let aggregateRate = (try? aggregateID.read(kAudioDevicePropertyNominalSampleRate, default: Float64(0))) ?? 0
            guard let sampleRate = aggregateRate > 0 ? aggregateRate : tapRate else {
                throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "Reading the sample rate")
            }
            let io = IOState(sampleRate: sampleRate)
            let writer = try Writer(url: url, format: format, io: io) { [weak self] error in
                guard let onFailure = self?.onFailure else { return }
                DispatchQueue.main.async { onFailure(error) }
            }
            self.io = io
            self.writer = writer
            writer.start()
            try startIO(io)
        } catch {
            stop()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Stops capture, drains the ring, finalizes the file and stores its waveform. Returns the final stats.
    @discardableResult
    func stop() -> Stats {
        if aggregateID != .unknown, let ioProcID {
            // After AudioDeviceStop returns, the IO block will not run again.
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if let keepAlive {
            AudioDeviceStop(keepAlive.device, keepAlive.procID)
            AudioDeviceDestroyIOProcID(keepAlive.device, keepAlive.procID)
            self.keepAlive = nil
        }
        writer?.finish()
        let final = stats
        writer = nil
        io = nil
        if aggregateID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        return final
    }

    private func createTap(for source: AudioSource) throws {
        // Rotap itself is tapped too: its keep-alive silence is what drives the tap while nothing else plays.
        // It never plays anything audible while recording (playback is disabled then).
        let description: CATapDescription
        if source.isSystem {
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        } else {
            guard !source.processObjectIDs.isEmpty else {
                throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "Finding \(source.name)’s audio processes")
            }
            let own = (try? AudioObjectID.processObject(for: ProcessInfo.processInfo.processIdentifier)) ?? .unknown
            description = CATapDescription(stereoMixdownOfProcesses: source.processObjectIDs + (own == .unknown ? [] : [own]))
        }
        description.uuid = UUID()
        description.name = "Rotap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Creating the audio tap")
        self.tapID = tapID
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        let format = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        guard isFloat32, format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "Reading the tap’s audio format")
        }
        return format
    }

    private func createAggregateDevice(includeTap: Bool, microphoneUID: String?) throws {
        // Only what is recorded goes in. Adding the output device as well would pull in its input streams
        // (e.g. AirPods' microphone, which forces them into the low-quality call profile) and tie the recording
        // to that device, so switching speakers mid-recording would break it.
        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rotap",
            kAudioAggregateDeviceUIDKey: "rotap.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
        ]
        if let microphoneUID {
            // The microphone is the clock; the tap is drift-compensated against it.
            description[kAudioAggregateDeviceMainSubDeviceKey] = microphoneUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: microphoneUID]]
        }
        if includeTap {
            let tapUID = try tapID.readString(kAudioTapPropertyUID)
            description[kAudioAggregateDeviceTapAutoStartKey] = true
            description[kAudioAggregateDeviceTapListKey] = [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]]
        }
        var aggregateID = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "Creating the aggregate device")
        self.aggregateID = aggregateID
    }

    /// A process tap only produces frames while a tapped process is playing, and a stalled tap stalls the whole
    /// aggregate, microphone included. Playing silence from Rotap (which the tap includes) keeps it running, so
    /// the recording starts immediately and keeps real time even when nothing else is playing.
    /// Best effort: without it the tap still works, it just waits for the first sound.
    private func startOutputKeepAlive() {
        guard let device = try? AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID.unknown),
              device != .unknown
        else { return }
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard status == noErr, let procID else { return }
        guard AudioDeviceStart(device, procID) == noErr else {
            AudioDeviceDestroyIOProcID(device, procID)
            return
        }
        keepAlive = (device, procID)
    }

    private func startIO(_ io: IOState) throws {
        var ioProcID: AudioDeviceIOProcID?
        // nil queue: the block runs directly on the HAL's real-time IO thread.
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, _, _ in
            io.receive(input)
        }, "Registering the audio callback")
        self.ioProcID = ioProcID
        try check(AudioDeviceStart(aggregateID, ioProcID), "Starting the recording")
    }
}

/// Everything the real-time callback touches. Immutable apart from atomics, the ring buffer and the mix scratch.
private final class IOState: @unchecked Sendable {
    /// Recordings are always stereo; mono inputs are spread to both sides.
    let channels = 2
    let sampleRate: Double
    let ring: SampleRingBuffer
    let frames = Atomic<Int64>(0)
    let droppedFrames = Atomic<Int64>(0)

    private static let chunkFrames = 4096
    /// Only touched by the IO thread.
    private let mix: UnsafeMutablePointer<Float>

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        // 8 seconds of headroom: the writer can stall that long (slow disk, AAC encoder hiccup) without loss.
        ring = SampleRingBuffer(minimumCapacity: Int(sampleRate * 8) * channels)
        mix = .allocate(capacity: Self.chunkFrames * channels)
        mix.initialize(repeating: 0, count: Self.chunkFrames * channels)
    }

    deinit { mix.deallocate() }

    /// Sums every input stream (tap and/or microphone) into interleaved stereo and publishes it.
    func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frameCount = Int.max
        for buffer in buffers where buffer.mNumberChannels > 0 {
            frameCount = min(frameCount, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * Int(buffer.mNumberChannels)))
        }
        guard frameCount != .max, frameCount > 0 else { return }

        var offset = 0
        while offset < frameCount {
            let count = min(Self.chunkFrames, frameCount - offset)
            mixChunk(buffers, from: offset, frames: count)
            if ring.write(mix, count: count * channels) {
                frames.add(Int64(count), ordering: .relaxed)
            } else {
                droppedFrames.add(Int64(count), ordering: .relaxed)
            }
            offset += count
        }
    }

    private func mixChunk(_ buffers: UnsafeMutableAudioBufferListPointer, from offset: Int, frames count: Int) {
        vDSP_vclr(mix, 1, vDSP_Length(count * channels))
        let n = vDSP_Length(count)
        for buffer in buffers {
            let streamChannels = Int(buffer.mNumberChannels)
            guard streamChannels > 0, let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let source = data + offset * streamChannels
            let stride = vDSP_Stride(streamChannels)
            // Mono feeds both sides; wider streams contribute their first two channels.
            let right = streamChannels > 1 ? source + 1 : source
            vDSP_vadd(source, stride, mix, 2, mix, 2, n)
            vDSP_vadd(right, stride, mix + 1, 2, mix + 1, 2, n)
        }
    }
}

/// Drains the ring on its own thread: encodes/writes the file and builds the waveform envelope.
private final class Writer: @unchecked Sendable {
    private let url: URL
    private let io: IOState
    private let onFailure: @Sendable (Error) -> Void
    private let finishing = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    private let live = Mutex(LivePeaks(levels: [], total: 0))
    let heardSound = Atomic<Bool>(false)

    // Owned by the writer thread once started.
    private var file: AVAudioFile?
    private let buffer: AVAudioPCMBuffer
    private var accumulator: WaveformAccumulator
    private var published = 0
    private var failed = false
    /// Peaks kept for the live meter; the full envelope lives in `accumulator`.
    private static let liveHistory = 1200

    init(url: URL, format: OutputFormat, io: IOState, onFailure: @escaping @Sendable (Error) -> Void) throws {
        self.url = url
        self.io = io
        self.onFailure = onFailure
        guard let pcm = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: io.sampleRate,
            channels: AVAudioChannelCount(io.channels), interleaved: true
        ), let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 8192) else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "Preparing the audio buffer")
        }
        self.buffer = buffer
        file = try AVAudioFile(
            forWriting: url,
            settings: format.settings(sampleRate: io.sampleRate, channels: AVAudioChannelCount(io.channels)),
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )
        accumulator = WaveformAccumulator(sampleRate: io.sampleRate)
    }

    func start() {
        let thread = Thread { [self] in run() }
        thread.name = "Rotap Writer"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Blocks until everything captured so far is on disk and the file is closed.
    func finish() {
        finishing.store(true, ordering: .releasing)
        done.wait()
    }

    func recentPeaks(_ count: Int) -> LivePeaks {
        live.withLock { LivePeaks(levels: Array($0.levels.suffix(count)), total: $0.total) }
    }

    private func run() {
        while true {
            // Read the flag before draining, so samples published before `finish()` are never left behind.
            let stopping = finishing.load(ordering: .acquiring)
            let drained = drain()
            if stopping { break }
            if !drained { Thread.sleep(forTimeInterval: 0.02) }
        }
        let envelope = accumulator.finish()
        file = nil  // closes and finalizes the container
        if !failed { Waveform.store(envelope, on: url) }
        done.signal()
    }

    /// Returns whether anything was read.
    private func drain() -> Bool {
        guard let samples = buffer.floatChannelData?[0] else { return false }
        let channels = io.channels
        var didRead = false
        while true {
            let count = io.ring.read(into: samples, maxSamples: Int(buffer.frameCapacity) * channels)
            guard count > 0 else { return didRead }
            didRead = true
            let frames = count / channels
            buffer.frameLength = AVAudioFrameCount(frames)

            accumulator.add([UnsafePointer(samples)], stride: channels, frames: frames)
            if accumulator.peaks.count > published {
                let fresh = accumulator.peaks[published...]
                published = accumulator.peaks.count
                if fresh.contains(where: { $0 > 0 }) { heardSound.store(true, ordering: .relaxed) }
                let total = published
                live.withLock { live in
                    live.levels.append(contentsOf: fresh)
                    if live.levels.count > Self.liveHistory { live.levels.removeFirst(live.levels.count - Self.liveHistory) }
                    live.total = total
                }
            }

            guard !failed, let file else { continue }
            do {
                try file.write(from: buffer)
            } catch {
                failed = true
                onFailure(error)
            }
        }
    }
}
