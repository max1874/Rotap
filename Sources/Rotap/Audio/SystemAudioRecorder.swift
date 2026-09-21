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

/// Records system (or per-app) audio through a Core Audio process tap.
///
/// Pipeline: HAL real-time IO thread → lock-free ring buffer → writer thread (encode, write, waveform).
/// The IO callback only copies samples; nothing on it allocates, locks or touches the disk.
/// Playback routing is untouched: no virtual device, the tap just listens alongside the real output.
final class SystemAudioRecorder: @unchecked Sendable {
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

    func start(source: AudioSource, url: URL, format: OutputFormat) throws {
        stop()
        do {
            try createTap(for: source)
            let tapFormat = try readTapFormat()
            try createAggregateDevice()

            let channels = Int(tapFormat.mChannelsPerFrame)
            let io = IOState(sampleRate: tapFormat.mSampleRate, channels: channels)
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
        let description: CATapDescription
        if source.isSystem {
            let own = (try? AudioObjectID.processObject(for: ProcessInfo.processInfo.processIdentifier)) ?? .unknown
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own == .unknown ? [] : [own])
        } else {
            guard !source.processObjectIDs.isEmpty else {
                throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "定位「\(source.name)」的音频进程")
            }
            description = CATapDescription(stereoMixdownOfProcesses: source.processObjectIDs)
        }
        description.uuid = UUID()
        description.name = "Rotap"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tapID), "创建音频 Tap")
        self.tapID = tapID
    }

    private func readTapFormat() throws -> AudioStreamBasicDescription {
        let format = try tapID.read(kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        guard isFloat32, format.mChannelsPerFrame > 0, format.mSampleRate > 0 else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "解析 Tap 音频格式")
        }
        return format
    }

    private func createAggregateDevice() throws {
        let tapUID = try tapID.readString(kAudioTapPropertyUID)
        // The aggregate holds only the tap. Adding the output device as a sub-device would also pull in its
        // input streams (e.g. AirPods' microphone, which forces them into the low-quality call profile) and
        // tie the recording to that device, so switching speakers mid-recording would break it.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Rotap Tap",
            kAudioAggregateDeviceUIDKey: "rotap.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregateID = AudioObjectID.unknown
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "创建聚合设备")
        self.aggregateID = aggregateID
    }

    private func startIO(_ io: IOState) throws {
        var ioProcID: AudioDeviceIOProcID?
        // nil queue: the block runs directly on the HAL's real-time IO thread.
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, _, _ in
            io.receive(input)
        }, "注册音频回调")
        self.ioProcID = ioProcID
        try check(AudioDeviceStart(aggregateID, ioProcID), "启动录音")
    }
}

/// Everything the real-time callback touches. Immutable apart from atomics and the ring buffer.
private final class IOState: Sendable {
    let sampleRate: Double
    let channels: Int
    let ring: SampleRingBuffer
    let frames = Atomic<Int64>(0)
    let droppedFrames = Atomic<Int64>(0)

    init(sampleRate: Double, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
        // 8 seconds of headroom: the writer can stall that long (slow disk, AAC encoder hiccup) without loss.
        ring = SampleRingBuffer(minimumCapacity: Int(sampleRate * 8) * channels)
    }

    func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, first.mNumberChannels > 0 else { return }
        let frameCount = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * Int(first.mNumberChannels))
        guard frameCount > 0 else { return }
        if ring.write(buffers, frames: frameCount, channels: channels) {
            frames.add(Int64(frameCount), ordering: .relaxed)
        } else {
            droppedFrames.add(Int64(frameCount), ordering: .relaxed)
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
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, operation: "准备音频缓冲")
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
