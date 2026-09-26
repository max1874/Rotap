import Synchronization

/// Lock-free single-producer / single-consumer ring of interleaved Float32 samples.
///
/// The producer is Core Audio's real-time IO thread, so `write` never allocates, locks or blocks:
/// it copies and publishes with a release store.
final class SampleRingBuffer: @unchecked Sendable {
    let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init(minimumCapacity: Int) {
        var capacity = 1
        while capacity < minimumCapacity { capacity <<= 1 }
        self.capacity = capacity
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Producer side. Returns false (and writes nothing) when the consumer has fallen too far behind.
    func write(_ source: UnsafePointer<Float>, count samples: Int) -> Bool {
        let head = writeIndex.load(ordering: .relaxed)
        let tail = readIndex.load(ordering: .acquiring)
        guard capacity - (head - tail) >= samples else { return false }
        let start = head & mask
        let first = min(samples, capacity - start)
        (storage + start).update(from: source, count: first)
        if first < samples { storage.update(from: source + first, count: samples - first) }
        writeIndex.store(head + samples, ordering: .releasing)
        return true
    }

    /// Consumer side. Copies up to `maxSamples` into `destination`; returns the number copied.
    func read(into destination: UnsafeMutablePointer<Float>, maxSamples: Int) -> Int {
        let tail = readIndex.load(ordering: .relaxed)
        let head = writeIndex.load(ordering: .acquiring)
        let count = min(head - tail, maxSamples)
        guard count > 0 else { return 0 }
        let start = tail & mask
        let first = min(count, capacity - start)
        destination.update(from: storage + start, count: first)
        if first < count { (destination + first).update(from: storage, count: count - first) }
        readIndex.store(tail + count, ordering: .releasing)
        return count
    }
}
