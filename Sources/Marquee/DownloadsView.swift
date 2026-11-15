#if os(iOS)
import MarqueeCore
import SwiftUI

/// Download control for a movie or episode. Not downloaded: tap to download. Downloading: a progress ring whose menu
/// pauses or cancels. Paused: the ring with an arrow, whose menu resumes or deletes. Downloaded: a menu to delete.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let item: Item
    var size: CGFloat = 44
    /// Title pages use a filled circle like the buttons next to it; episode rows and the Downloads list a bare icon.
    var circled = true

    var body: some View {
        let downloads = Downloads.shared
        let entry = downloads.entry(item.id)
        Group {
            switch entry?.state {
            case .downloading:
                Menu {
                    Button("Pause Download", systemImage: "pause") { downloads.pause(item.id) }
                    Button("Cancel Download", systemImage: "xmark", role: .destructive) { downloads.delete(item.id) }
                } label: {
                    ring(entry?.progress ?? 0, symbol: "pause.fill")
                }
                .accessibilityLabel("Downloading, \(Int((entry?.progress ?? 0) * 100)) percent")
            case .paused:
                Menu {
                    Button("Resume Download", systemImage: "arrow.down") { downloads.start(item, client: model.client) }
                    Button("Delete Download", systemImage: "trash", role: .destructive) { downloads.delete(item.id) }
                } label: {
                    ring(entry?.progress ?? 0, symbol: "arrow.down", dimmed: true)
                }
                .accessibilityLabel("Download paused, \(Int((entry?.progress ?? 0) * 100)) percent")
            case .finished:
                Menu {
                    Button("Delete Download", systemImage: "trash", role: .destructive) { downloads.delete(item.id) }
                } label: {
                    icon("arrow.down.circle.fill").foregroundStyle(.blue)
                }
                .accessibilityLabel("Downloaded")
            case .failed:
                Menu {
                    Button("Try Again", systemImage: "arrow.clockwise") { downloads.start(item, client: model.client) }
                    Button("Delete Download", systemImage: "trash", role: .destructive) { downloads.delete(item.id) }
                } label: {
                    icon("exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.red)
                }
                .accessibilityLabel("Download failed")
            case nil:
                Button { downloads.start(item, client: model.client) } label: {
                    icon("arrow.down.to.line")
                }
                .accessibilityLabel("Download")
            }
        }
        .buttonStyle(.plain)
    }

    private func ring(_ progress: Double, symbol: String, dimmed: Bool = false) -> some View {
        ProgressRing(progress: progress, symbol: symbol, dimmed: dimmed)
            .padding(size * 0.2)
            .frame(width: size, height: size)
            .background(circled ? Color.white.opacity(0.15) : .clear, in: Circle())
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: size * (circled ? 0.4 : 0.6), weight: .semibold))
            .frame(width: size, height: size)
            .background(circled ? Color.white.opacity(0.15) : .clear, in: Circle())
    }
}

private struct ProgressRing: View {
    let progress: Double
    let symbol: String
    var dimmed = false

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(progress, 0.02))
                .stroke(dimmed ? .white.opacity(0.6) : .white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: progress)
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
        }
    }
}

/// Everything saved for offline viewing. Works without a connection: art and details are stored with the files.
/// Tapping a title plays it, even mid-download (up to the part that has arrived).
struct DownloadsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let downloads = Downloads.shared
        let entries = downloads.all
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: 4) {
                        Button { Player.play(entry.item, client: model.client, fromDownloads: true) } label: {
                            DownloadRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .disabled(!entry.isPlayable)
                        DownloadButton(item: entry.item, size: 36, circled: false)
                    }
                    .listRowBackground(Color.clear)
                }
                .onDelete { offsets in
                    for index in offsets { downloads.delete(entries[index].id) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No downloads", systemImage: "arrow.down.circle",
                                           description: Text("Tap the download button on a movie or episode to watch it without a connection."))
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

private struct DownloadRow: View {
    let entry: Downloads.Entry

    private var title: String {
        entry.item.isEpisode ? (entry.item.seriesName ?? "") : (entry.item.name ?? "")
    }

    private var subtitle: String? {
        guard entry.item.isEpisode else { return Format.meta(entry.item) }
        return [Format.episodeLabel(entry.item), entry.item.name].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let url = Downloads.shared.imageURL(for: entry.id), let image = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color(white: 0.14)
                }
                if entry.isPlayable {
                    Image(systemName: "play.circle").font(.title2)
                }
            }
            .frame(width: 128, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.bold()).lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var status: some View {
        let done = ByteCountFormatter.string(fromByteCount: entry.fileLength, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: entry.estimatedBytes, countStyle: .file)
        let percent = Int(entry.progress * 100)
        switch entry.state {
        case .finished:
            Text(done).font(.caption).foregroundStyle(.secondary)
        case .downloading, .paused:
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: entry.progress).tint(entry.state == .paused ? .gray : .red)
                Group {
                    if entry.state == .paused {
                        Text(entry.interrupted ? "Waiting to resume · \(percent)%" : "Paused · \(percent)%")
                    } else if entry.segmentCount == 0 {
                        Text("Starting…")
                    } else {
                        Text("\(percent)% · \(done) of ~\(total)")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if entry.isPlayable {
                    Text("Watch the first \(Format.runtime(Int64(entry.secondsDone * Format.ticksPerSecond)) ?? "part") now")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        case .failed:
            Text("Download failed. Use the menu to try again.").font(.caption).foregroundStyle(.red)
        }
    }
}
#endif
