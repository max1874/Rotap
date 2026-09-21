import AppKit
import AVFoundation
import Observation

struct Recording: Identifiable, Hashable, Sendable {
    let url: URL
    let date: Date
    let size: Int64
    var duration: TimeInterval?

    var id: URL { url }
    var fileName: String { url.deletingPathExtension().lastPathComponent }
    var format: String { url.pathExtension.uppercased() }

    /// Files are named "<source> <yyyy-MM-dd HH.mm.ss>" so they sort and stay unique in Finder.
    /// In the app the timestamp is shown separately, so an untouched name displays as just its source;
    /// anything the user renamed displays verbatim.
    var title: String {
        guard let match = fileName.wholeMatch(of: Self.generatedName) else { return fileName }
        return String(match.output.1)
    }

    nonisolated(unsafe) private static let generatedName = /(.+) \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}(?: \d+)?/

    static func newURL(in directory: URL, source: AudioSource, format: OutputFormat) -> URL {
        let label = source.label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let base = "\(label) \(Date.now.formatted(Self.stamp))"
        var url = directory.appendingPathComponent(base).appendingPathExtension(format.rawValue)
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(index)").appendingPathExtension(format.rawValue)
            index += 1
        }
        return url
    }

    private static let stamp = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits).\(second: .twoDigits)",
        timeZone: .current, calendar: Calendar(identifier: .gregorian)
    )
}

/// The recordings folder, kept in sync with disk through a directory watcher (no polling).
@MainActor
@Observable
final class RecordingLibrary {
    nonisolated static let audioExtensions: Set<String> = ["m4a", "wav", "caf", "aiff", "mp3"]

    private(set) var recordings: [Recording] = []
    private(set) var directory: URL?
    /// The file currently being written; hidden until it is finalized.
    var activeRecording: URL? {
        didSet { if activeRecording != oldValue { scheduleReload() } }
    }

    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var durations: [URL: (Date, TimeInterval)] = [:]

    func watch(_ directory: URL) {
        guard directory != self.directory else { return }
        self.directory = directory
        watcher?.cancel()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.scheduleReload() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
        reload()
    }

    func reload() {
        reloadTask?.cancel()
        reloadTask = Task { await performReload() }
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await performReload()
        }
    }

    private func performReload() async {
        guard let directory else { return }
        let hidden = activeRecording
        let known = durations
        let (items, measured) = await Task.detached(priority: .utility) {
            Self.scan(directory, hiding: hidden, knownDurations: known)
        }.value
        guard !Task.isCancelled else { return }
        durations = measured
        recordings = items
    }

    nonisolated private static func scan(
        _ directory: URL, hiding hidden: URL?, knownDurations: [URL: (Date, TimeInterval)]
    ) -> ([Recording], [URL: (Date, TimeInterval)]) {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []

        var measured: [URL: (Date, TimeInterval)] = [:]
        let recordings = urls.compactMap { url -> Recording? in
            guard audioExtensions.contains(url.pathExtension.lowercased()),
                  url.standardizedFileURL != hidden?.standardizedFileURL,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { return nil }
            let modified = values.contentModificationDate ?? .distantPast
            var duration = knownDurations[url].flatMap { $0.0 == modified ? $0.1 : nil }
            if duration == nil, let file = try? AVAudioFile(forReading: url) {
                duration = Double(file.length) / file.fileFormat.sampleRate
            }
            if let duration { measured[url] = (modified, duration) }
            return Recording(
                url: url,
                date: values.creationDate ?? modified,
                size: Int64(values.fileSize ?? 0),
                duration: duration
            )
        }
        return (recordings.sorted { $0.date > $1.date }, measured)
    }

    /// Renames the file on disk; returns the new URL.
    func rename(_ recording: Recording, to title: String) throws -> URL {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !trimmed.isEmpty, trimmed != recording.title else { return recording.url }
        let destination = recording.url.deletingLastPathComponent()
            .appendingPathComponent(trimmed).appendingPathExtension(recording.url.pathExtension)
        try FileManager.default.moveItem(at: recording.url, to: destination)
        reload()
        return destination
    }

    func moveToTrash(_ recording: Recording) throws {
        try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        recordings.removeAll { $0.url == recording.url }
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.url])
    }
}
