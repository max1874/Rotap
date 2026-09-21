import SwiftUI

struct SidebarView: View {
    @Environment(RecordingLibrary.self) private var library
    @Environment(PlaybackModel.self) private var player
    @Binding var selection: URL?

    @State private var query = ""

    private var sections: [(title: String, items: [Recording])] {
        let filtered = query.isEmpty
            ? library.recordings
            : library.recordings.filter { $0.title.localizedStandardContains(query) }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            (Self.sectionTitle(for: day, calendar: calendar), grouped[day]!)
        }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.items) { recording in
                        RecordingRow(recording: recording)
                            .tag(recording.url)
                            .contextMenu { contextMenu(for: recording) }
                    }
                }
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "搜索录音")
        .onKeyPress(.space) {
            guard player.url != nil else { return .ignored }
            player.toggle()
            return .handled
        }
        .onDeleteCommand {
            if let recording = library.recordings.first(where: { $0.url == selection }) { trash(recording) }
        }
        .overlay {
            if library.recordings.isEmpty {
                Text("还没有录音")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if !query.isEmpty && sections.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for recording: Recording) -> some View {
        Button("在 Finder 中显示", systemImage: "folder") { library.reveal(recording) }
        ShareLink(item: recording.url)
        Divider()
        Button("移到废纸篓", systemImage: "trash", role: .destructive) { trash(recording) }
    }

    private func trash(_ recording: Recording) {
        let items = library.recordings
        if selection == recording.url {
            let index = items.firstIndex(of: recording) ?? 0
            let neighbor = items.indices.contains(index + 1) ? items[index + 1] : (index > 0 ? items[index - 1] : nil)
            player.load(nil)
            selection = neighbor?.url
        }
        try? library.moveToTrash(recording)
    }

    private static func sectionTitle(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let sameYear = calendar.isDate(day, equalTo: .now, toGranularity: .year)
        return day.formatted(sameYear ? .dateTime.month().day().weekday() : .dateTime.year().month().day())
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title)
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(recording.date, format: .dateTime.hour().minute())
                if let duration = recording.duration {
                    Text(PlayerView.time(duration))
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
                Text(recording.format)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
