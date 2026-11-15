#if os(iOS)
import Foundation
import MarqueeCore
import Observation
import UIKit

/// Offline copies of movies and episodes.
///
/// Each download asks Jellyfin for its HLS stream (which copies the video and audio instead of re-encoding them when
/// the iPhone can play them) and fetches the segments one by one, appending them to a single fragmented MP4. So a
/// download can pause between any two segments, resume later from where it stopped, and the part already fetched
/// plays at any time. FMP4Joiner keeps the file in one piece where a resumed download picks up. Files live in Application Support/Downloads (not backed up), next to a small JSON index.
@MainActor
@Observable
final class Downloads {
    static let shared = Downloads()

    struct Entry: Codable, Identifiable {
        enum State: String, Codable { case downloading, paused, finished, failed }

        var item: Item
        var state: State
        /// Paused by leaving the app or losing the connection rather than by the user, so it resumes by itself.
        var interrupted = false
        var segmentsDone = 0
        var segmentCount = 0
        var secondsDone: Double = 0
        var secondsTotal: Double = 0
        /// Bytes in the file that are known to be complete (init segment plus whole media segments).
        var fileLength: Int64 = 0
        /// Keeps the file playable across restarts of the server's conversion; see FMP4Joiner.
        var joiner = FMP4Joiner()
        /// Text subtitle tracks saved next to the video (nil until fetched; optional so older index files still load).
        var subtitles: [MediaStream]?
        /// Where playback stopped, kept locally so offline viewing resumes too.
        var positionSeconds: Double?
        var added = Date()

        var id: String { item.id }
        var progress: Double {
            if state == .finished { return 1 }
            return secondsTotal > 0 ? min(secondsDone / secondsTotal, 1) : 0
        }
        /// Expected final size, from the average so far.
        var estimatedBytes: Int64 {
            guard secondsDone > 0, secondsTotal > 0 else { return 0 }
            return Int64(Double(fileLength) * secondsTotal / secondsDone)
        }
        /// Enough has arrived to start watching.
        var isPlayable: Bool { state == .finished || secondsDone >= 20 }
    }

    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// The current run of each download; a cancelled run still finishing up leaves the entry alone.
    @ObservationIgnored private var runs: [String: UUID] = [:]

    private static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        return folder
    }()
    private static var indexURL: URL { folder.appendingPathComponent("index.json") }
    private static func file(_ id: String) -> URL { folder.appendingPathComponent("\(id).mp4") }
    private static func image(_ id: String) -> URL { folder.appendingPathComponent("\(id).jpg") }
    private static func subtitle(_ id: String, _ index: Int) -> URL { folder.appendingPathComponent("\(id).sub\(index).vtt") }

    private init() {
        if let data = try? Data(contentsOf: Self.indexURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        }
        // Downloads cut off when the app quit pick up again on the next resumeInterrupted(client:).
        for (id, entry) in entries where entry.state == .downloading {
            entries[id]?.state = .paused
            entries[id]?.interrupted = true
        }
    }

    // MARK: - Reading

    var all: [Entry] { entries.values.sorted { $0.added > $1.added } }

    func entry(_ id: String) -> Entry? { entries[id] }

    /// The local file to play: always for a finished download, and for one still under way (or paused) when
    /// `allowPartial` is set and enough has arrived. It plays up to where the download has got to.
    func playableFile(for id: String, allowPartial: Bool = false) -> URL? {
        guard let entry = entries[id], entry.state == .finished || (allowPartial && entry.isPlayable) else { return nil }
        let url = Self.file(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A saved subtitle track (WebVTT), for playing offline.
    func subtitleFile(for id: String, index: Int) -> URL? {
        let url = Self.subtitle(id, index)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func imageURL(for id: String) -> URL? {
        let url = Self.image(id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The next downloaded episode of the same show, for rolling on while offline.
    func nextDownloadedEpisode(after episode: Item) -> Item? {
        func order(_ item: Item) -> (Int, Int) { (item.parentIndexNumber ?? 0, item.indexNumber ?? 0) }
        return entries.values
            .filter { $0.state == .finished && $0.item.seriesId != nil && $0.item.seriesId == episode.seriesId }
            .map(\.item)
            .filter { order($0) > order(episode) }
            .min { order($0) < order($1) }
    }

    // MARK: - Changing

    /// Starts a download, or resumes a paused or failed one from where it stopped.
    func start(_ item: Item, client: JellyfinClient) {
        if entries[item.id] == nil {
            entries[item.id] = Entry(item: item, state: .downloading)
        }
        let id = item.id
        guard entries[id]?.state != .finished, !(entries[id]?.state == .downloading && tasks[id] != nil) else { return }
        stop(id)
        entries[id]?.state = .downloading
        entries[id]?.interrupted = false
        save()
        let run = UUID()
        runs[id] = run
        tasks[id] = Task { await download(id, run: run, client: client) }
    }

    private func stop(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        runs[id] = nil
    }

    func pause(_ id: String) {
        guard entries[id]?.state == .downloading else { return }
        entries[id]?.state = .paused
        entries[id]?.interrupted = false
        stop(id)
        save()
    }

    /// Resumes downloads that stopped because the app went to the background, quit or lost its connection.
    func resumeInterrupted(client: JellyfinClient) {
        for entry in entries.values where entry.state == .paused && entry.interrupted {
            start(entry.item, client: client)
        }
        // Downloads from before subtitles were saved with them.
        for entry in entries.values where entry.state == .finished && entry.subtitles == nil {
            let id = entry.id
            Task {
                guard let info = try? await client.playbackInfo(itemId: id, profile: DeviceProfile.avPlayer(), subtitleIndex: -1),
                      let source = info.mediaSources?.first, entries[id] != nil else { return }
                await saveSubtitles(id, source, client: client)
            }
        }
    }

    func delete(_ id: String) {
        stop(id)
        try? FileManager.default.removeItem(at: Self.file(id))
        try? FileManager.default.removeItem(at: Self.image(id))
        for track in entries[id]?.subtitles ?? [] {
            try? FileManager.default.removeItem(at: Self.subtitle(id, track.index))
        }
        entries[id] = nil
        save()
    }

    func savePosition(_ id: String, seconds: Double) {
        guard entries[id] != nil else { return }
        entries[id]?.positionSeconds = seconds
        save()
    }

    // MARK: - Downloading

    private func download(_ id: String, run: UUID, client: JellyfinClient) async {
        // A little extra time to finish the current segment when the app leaves the screen; after that iOS
        // suspends the app, so the download stops and picks up again when the app comes back.
        var background = UIBackgroundTaskIdentifier.invalid
        background = UIApplication.shared.beginBackgroundTask(withName: "download") { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.runs[id] == run else { return }
                self.entries[id]?.state = .paused
                self.entries[id]?.interrupted = true
                self.save()
                self.stop(id)
                UIApplication.shared.endBackgroundTask(background)
            }
        }
        var playSessionId: String?
        do {
            if entries[id]?.segmentsDone == 0, let full = try? await client.item(id) {
                entries[id]?.item = full   // fresh details (runtime, resume point) kept with the file
            }
            if imageURL(for: id) == nil, let item = entries[id]?.item { await saveImage(for: item, client: client) }

            // subtitleIndex -1: nothing drawn into the video; the player shows the saved text subtitles itself.
            let info = try await client.playbackInfo(itemId: id, profile: DeviceProfile.avPlayer(), subtitleIndex: -1,
                                                     allowDirectPlay: false)
            if entries[id]?.subtitles == nil, let source = info.mediaSources?.first {
                await saveSubtitles(id, source, client: client)
            }
            playSessionId = info.playSessionId
            let playlist = try await client.downloadPlaylist(info)
            try await fetch(id, playlist, client: client)
        } catch {
            if runs[id] == run {
                // Lost connection or similar: try again when the app next becomes active; anything else failed.
                let transient = error is URLError || error is CancellationError
                entries[id]?.state = transient ? .paused : .failed
                entries[id]?.interrupted = transient
            }
        }
        if runs[id] == run {
            save()
            tasks[id] = nil
            runs[id] = nil
        }
        // Let Jellyfin stop its conversion for this download right away.
        if let playSessionId { Task { await client.stopEncoding(playSessionId: playSessionId) } }
        UIApplication.shared.endBackgroundTask(background)
    }

    private func fetch(_ id: String, _ playlist: HLSPlaylist, client: JellyfinClient) async throws {
        let url = Self.file(id)
        guard var entry = entries[id] else { return }
        // Start over if there's nothing yet, the file went missing, or the server cut the stream up differently.
        if entry.segmentsDone == 0 || entry.segmentCount != playlist.segments.count
            || !FileManager.default.fileExists(atPath: url.path) {
            guard let initURL = playlist.initURL else { throw JellyfinError.noPlayableSource }
            let header = try await client.data(from: initURL)
            try header.write(to: url)
            entry.segmentsDone = 0
            entry.segmentCount = playlist.segments.count
            entry.secondsDone = 0
            entry.secondsTotal = playlist.duration
            entry.fileLength = Int64(header.count)
            entry.joiner = FMP4Joiner()
            entries[id] = entry
            save()
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        // Drop any half-written segment from a download that was cut off mid-write.
        try handle.truncate(atOffset: UInt64(entry.fileLength))
        try handle.seekToEnd()

        for index in entry.segmentsDone..<playlist.segments.count {
            try Task.checkCancellation()
            let segment = playlist.segments[index]
            let data = try await client.data(from: segment.url)
            try Task.checkCancellation()
            guard var joiner = entries[id]?.joiner else { return }
            let joined = joiner.append(data)
            try handle.write(contentsOf: joined)
            entries[id]?.joiner = joiner
            entries[id]?.segmentsDone = index + 1
            entries[id]?.secondsDone += segment.duration
            entries[id]?.fileLength += Int64(joined.count)
            save()
        }
        entries[id]?.state = .finished
        entries[id]?.interrupted = false
    }

    /// Every text subtitle track of the file; they're small (tens of KB each).
    private func saveSubtitles(_ id: String, _ source: MediaSource, client: JellyfinClient) async {
        var saved: [MediaStream] = []
        for track in source.mediaStreams ?? [] where track.isSubtitle && track.isText {
            let url = client.subtitleURL(itemId: id, mediaSourceId: source.id, index: track.index)
            guard let data = try? await client.data(from: url, timeout: 30), !data.isEmpty,
                  (try? data.write(to: Self.subtitle(id, track.index))) != nil else { continue }
            saved.append(track)
        }
        entries[id]?.subtitles = saved
        save()
    }

    private func saveImage(for item: Item, client: JellyfinClient) async {
        guard let url = client.landscapeURL(item, width: 560),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        try? data.write(to: Self.image(item.id))
    }

    private func save() {
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            try? data.write(to: Self.indexURL, options: .atomic)
        }
    }
}
#endif
