#if os(iOS)
import AVFoundation
import AVKit
import MarqueeCore
import UIKit

/// Opens Apple's full-screen player (AVPlayerViewController) for the video, Picture in Picture and lock-screen
/// controls, with the app's own Netflix-style controls (PlayerControls) and subtitles (SubtitleControls) on top.
@MainActor
enum Player {
    private static var current: PlaybackSession?

    /// `fromDownloads`: started from the Downloads tab, so a download still under way plays as far as it has got.
    static func play(_ item: Item, client: JellyfinClient, fromDownloads: Bool = false) {
        guard let presenter = topViewController() else { return }
        current?.close()
        let session = PlaybackSession(client: client, item: item, allowPartialDownload: fromDownloads)
        session.onFinish = { [weak session] in
            if current === session { current = nil }
            NotificationCenter.default.post(name: .marqueeLibraryChanged, object: nil)
        }
        current = session
        session.start(from: presenter)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

/// One playback: asks Jellyfin how to stream, plays, resumes, reports progress, and rolls on to the next episode.
@MainActor
final class PlaybackSession: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private let client: JellyfinClient
    private var item: Item
    private let player = AVPlayer()
    private let controller = AVPlayerViewController()
    private let sideSliders = SideSliders()
    private let subtitles = SubtitleControls()
    private let controls = PlayerControls()
    private var nextEpisode: Item?
    private let masterPlaylistLoader = MasterPlaylistLoader()
    private var plan: PlaybackPlan?
    private var timeObserver: Any?
    private var subtitleObserver: Any?
    // Subtitles: the title's tracks, the one on (nil = off), and its lines. Picture subtitles can only be drawn into
    // the video by the server, so picking one reloads the stream with it (`burnedSubtitle`).
    private var subtitleStreams: [MediaStream] = []
    private var mediaSourceId: String?
    private var selectedSubtitle: Int?
    private var burnedSubtitle: Int?
    private var cues: [SubtitleCue] = []
    private var cueTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?
    private var loadTask: Task<Void, Never>?
    private var inPictureInPicture = false
    private var finished = false
    private let allowPartialDownload: Bool
    var onFinish: (() -> Void)?

    init(client: JellyfinClient, item: Item, allowPartialDownload: Bool = false) {
        self.client = client
        self.item = item
        self.allowPartialDownload = allowPartialDownload
        super.init()
        controller.player = player
        controller.delegate = self
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.modalPresentationStyle = .fullScreen
        controller.showsPlaybackControls = false
        sideSliders.install(on: controller)
        subtitles.install(on: controller)
        subtitles.onSelect = { [weak self] track in self?.selectSubtitle(track) }
        controls.onClose = { [weak self] in self?.close() }
        controls.onNextEpisode = { [weak self] in self?.playNext() }
        controls.subtitleOptions = { [weak self] in self?.subtitles.sections() ?? [] }
        controls.onVisibilityChange = { [weak self] visible in self?.subtitles.setLifted(visible) }
        controls.install(on: controller)
    }

    func start(from presenter: UIViewController) {
        presenter.present(controller, animated: true) { Orientation.lock(.landscape) }
        loadTask = Task { await load(item, startSeconds: nil) }
    }

    // MARK: - Loading

    /// `burn`: a picture subtitle for the server to draw in. `keepSubtitle`: a reload for a subtitle change, so keep
    /// the viewer's pick instead of choosing again.
    private func load(_ requested: Item, startSeconds: Double?, burn: Int? = nil, keepSubtitle: Bool = false) async {
        cueTask?.cancel()
        cues = []
        subtitles.update(text: nil)
        do {
            let playable: Item
            let plan: PlaybackPlan
            var start = startSeconds
            var streams: [MediaStream] = []
            var sourceId: String?
            var burned: Int?
            if let file = Downloads.shared.playableFile(for: requested.id, allowPartial: allowPartialDownload),
               let saved = Downloads.shared.entry(requested.id) {
                streams = saved.subtitles ?? []
                // Downloaded: play the file. The server's resume point counts when it answers quickly (we may be offline).
                let fresh = await quickFetch(requested.id)
                playable = fresh ?? saved.item
                plan = .downloaded(file, itemId: requested.id)
                start = start ?? max(saved.positionSeconds ?? 0, Format.resumeSeconds(playable))
                if saved.state != .finished, let wanted = start {
                    start = min(wanted, max(saved.secondsDone - 10, 0))   // not past what has arrived
                }
            } else {
                // Fresh copy for the latest resume point; shows/collections become their episode/title.
                let fresh = try await client.item(requested.id)
                playable = try await client.playableItem(for: fresh)
                if let file = Downloads.shared.playableFile(for: playable.id) {
                    plan = .downloaded(file, itemId: playable.id)
                    streams = Downloads.shared.entry(playable.id)?.subtitles ?? []
                } else {
                    // No subtitles from the server (-1) unless it has to draw a picture subtitle in; the app shows text ones.
                    var info = try await client.playbackInfo(itemId: playable.id, profile: DeviceProfile.avPlayer(),
                                                             subtitleIndex: burn ?? -1)
                    let source = info.mediaSources?.first
                    streams = source?.mediaStreams?.filter(\.isSubtitle) ?? []
                    sourceId = source?.id
                    burned = burn
                    if !keepSubtitle, burn == nil, let first = initialSubtitle(streams, allowPictures: true), !first.isText {
                        info = try await client.playbackInfo(itemId: playable.id, profile: DeviceProfile.avPlayer(),
                                                             subtitleIndex: first.index)
                        burned = first.index
                    }
                    plan = try client.plan(for: playable.id, info)
                }
            }
            item = playable
            self.plan = plan
            controls.setTitle(title(for: playable))
            findNextEpisode(after: playable)
            subtitleStreams = streams
            mediaSourceId = sourceId
            burnedSubtitle = burned
            if !keepSubtitle {
                selectedSubtitle = initialSubtitle(streams, allowPictures: !plan.url.isFileURL)?.index
            }
            subtitles.choices = .init(tracks: streams, selected: selectedSubtitle, allowPictureTracks: !plan.url.isFileURL)

            let avItem = AVPlayerItem(asset: masterPlaylistLoader.asset(for: plan.url))
            avItem.externalMetadata = metadata(for: playable)
            player.replaceCurrentItem(with: avItem)
            try await waitUntilReady(avItem)

            let begin = start ?? Format.resumeSeconds(playable)
            if begin > 1 {
                _ = await player.seek(to: CMTime(seconds: begin, preferredTimescale: 600))
            }
            try? AVAudioSession.sharedInstance().setActive(true)
            player.play()
            observe(avItem)
            loadCues()
            // After observing: offline, this report waits for its timeout.
            await client.report(.start, itemId: playable.id, plan: plan, positionSeconds: position, isPaused: false)
        } catch is CancellationError {
            // closed while loading
        } catch {
            showError(error)
        }
    }

    private func title(for item: Item) -> String {
        guard item.isEpisode else { return item.name ?? "" }
        let episode = [Format.episodeLabel(item), item.name.map { "“\($0)”" }].compactMap { $0 }.joined(separator: " ")
        return [item.seriesName, episode].compactMap { $0 }.joined(separator: ": ")
    }

    // MARK: - Next episode

    /// Looks up the next episode so the Next Episode button only shows when there is one.
    private func findNextEpisode(after current: Item) {
        nextEpisode = nil
        controls.setHasNextEpisode(false)
        guard current.isEpisode else { return }
        let client = client
        Task {
            let next = await quick({ try await client.nextEpisode(after: current) })
                ?? Downloads.shared.nextDownloadedEpisode(after: current)
            guard item.id == current.id else { return }   // moved on meanwhile
            nextEpisode = next
            controls.setHasNextEpisode(next != nil)
        }
    }

    private func playNext() {
        guard let next = nextEpisode else { return }
        loadTask?.cancel()
        loadTask = Task {
            await endStream()
            await load(next, startSeconds: 0)
        }
    }

    // MARK: - Subtitles

    /// The track to start with: the language picked last time (or Off), else the file's own default text subtitle.
    private func initialSubtitle(_ streams: [MediaStream], allowPictures: Bool) -> MediaStream? {
        let usable = streams.filter { $0.isSubtitle && ($0.isText || allowPictures) }
        switch UserDefaults.standard.string(forKey: "subtitleLanguage") {
        case "off": return nil
        case let language?: return Subtitles.pick(language, from: usable)
        case nil: return usable.first { $0.isDefault == true && $0.isText }
        }
    }

    private func selectSubtitle(_ track: MediaStream?) {
        // Remembered by language, so the next title starts the same way.
        let language = track.map { $0.languageCode ?? Subtitles.preferredLanguage } ?? "off"
        UserDefaults.standard.set(language, forKey: "subtitleLanguage")
        selectedSubtitle = track?.index
        if let track, !track.isText {
            reload(burn: track.index)
        } else if burnedSubtitle != nil {
            reload(burn: nil)   // take the drawn-in subtitle back out of the video
        } else {
            loadCues()
        }
    }

    /// Restarts the stream at the same spot, for a subtitle the server has to draw in (or stop drawing).
    private func reload(burn: Int?) {
        let at = position, current = item
        subtitles.flash(burn == nil ? "Turning off subtitles…" : "Loading subtitles…")
        loadTask?.cancel()
        loadTask = Task {
            await endStream()
            await load(current, startSeconds: at, burn: burn, keepSubtitle: true)
        }
    }

    private func loadCues() {
        cueTask?.cancel()
        cues = []
        subtitles.update(text: nil)
        guard let index = selectedSubtitle,
              let track = subtitleStreams.first(where: { $0.index == index }), track.isText else { return }
        let id = item.id, sourceId = mediaSourceId, client = client
        cueTask = Task {
            var result: [SubtitleCue] = []
            if let file = Downloads.shared.subtitleFile(for: id, index: index),
               let text = try? String(contentsOf: file, encoding: .utf8) {
                result = Subtitles.parseVTT(text)
            } else if let sourceId {
                result = (try? await client.subtitleCues(itemId: id, mediaSourceId: sourceId, index: index)) ?? []
            }
            guard !Task.isCancelled else { return }
            if result.isEmpty { subtitles.flash("Subtitles unavailable") } else { cues = result }
        }
    }

    /// The item from the server, or nil if it doesn't answer within 3 s (offline, or the server is unreachable).
    private func quickFetch(_ id: String) async -> Item? {
        let client = client
        return await quick { try await client.item(id) }
    }

    private func quick(_ work: @escaping @Sendable () async throws -> Item?) async -> Item? {
        await withTaskGroup(of: Item?.self) { group in
            group.addTask { try? await work() }
            group.addTask { try? await Task.sleep(for: .seconds(3)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// shortcut: polls the item's status every 0.1 s (max 30 s) instead of KVO; fine for a one-off wait.
    private func waitUntilReady(_ avItem: AVPlayerItem) async throws {
        for _ in 0..<300 {
            switch avItem.status {
            case .readyToPlay: return
            case .failed: throw avItem.error ?? JellyfinError.badResponse
            default: try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw JellyfinError.badResponse
    }

    private func metadata(for item: Item) -> [AVMetadataItem] {
        func entry(_ id: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value, !value.isEmpty else { return nil }
            let meta = AVMutableMetadataItem()
            meta.identifier = id
            meta.value = value as NSString
            meta.extendedLanguageTag = "und"
            return meta
        }
        let title = item.isEpisode
            ? [Format.episodeLabel(item), item.name].compactMap { $0 }.joined(separator: " · ")
            : item.name
        return [
            entry(.commonIdentifierTitle, title),
            entry(.iTunesMetadataTrackSubTitle, item.isEpisode ? item.seriesName : item.productionYear.map(String.init)),
            entry(.commonIdentifierDescription, item.overview),
        ].compactMap { $0 }
    }

    private var position: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    // MARK: - Progress and end of episode

    private func observe(_ avItem: AVPlayerItem) {
        removeObservers()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reportProgress() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playedToEnd() }
        }
        subtitleObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.subtitles.update(text: self.cues.isEmpty ? nil : Subtitles.text(at: time.seconds, in: self.cues))
            }
        }
    }

    private func removeObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let subtitleObserver { player.removeTimeObserver(subtitleObserver) }
        timeObserver = nil
        endObserver = nil
        subtitleObserver = nil
    }

    private func reportProgress() {
        guard let plan else { return }
        let client = client, id = item.id, pos = position, paused = player.timeControlStatus == .paused
        Task { await client.report(.progress, itemId: id, plan: plan, positionSeconds: pos, isPaused: paused) }
    }

    private func playedToEnd() {
        if plan?.url.isFileURL == true, let entry = Downloads.shared.entry(item.id), entry.state != .finished {
            waitForMoreDownloaded()
            return
        }
        let finishedItem = item
        Task {
            await endStream()
            let client = client
            guard finishedItem.isEpisode,
                  let next = await quick({ try await client.nextEpisode(after: finishedItem) })
                      ?? Downloads.shared.nextDownloadedEpisode(after: finishedItem) else {
                close()
                return
            }
            loadTask = Task { await load(next, startSeconds: 0) }
        }
    }

    /// Reached the end of what has downloaded so far: hold here, and carry on once more has arrived. If the download
    /// is paused or failed, the player just stays paused at this point.
    private func waitForMoreDownloaded() {
        let id = item.id, at = position, shown = item
        player.pause()
        loadTask?.cancel()
        loadTask = Task {
            while true {
                guard !Task.isCancelled, let entry = Downloads.shared.entry(id), entry.state == .downloading
                        || entry.state == .finished else { return }
                if entry.state == .finished || entry.secondsDone > at + 30 { break }
                try? await Task.sleep(for: .seconds(2))
            }
            // Reopen the file so the player sees the new part, and continue from the same spot.
            guard let file = Downloads.shared.playableFile(for: id, allowPartial: true) else { return }
            let avItem = AVPlayerItem(url: file)
            avItem.externalMetadata = metadata(for: shown)
            player.replaceCurrentItem(with: avItem)
            guard (try? await waitUntilReady(avItem)) != nil, !Task.isCancelled else { return }
            _ = await player.seek(to: CMTime(seconds: at, preferredTimescale: 600))
            player.play()
            observe(avItem)
        }
    }

    /// Tells Jellyfin this stream stopped (it saves the resume point) and frees any conversion.
    private func endStream() async {
        removeObservers()
        guard let plan else { return }
        self.plan = nil
        let pos = position
        player.pause()
        if plan.url.isFileURL {
            // A download: keep the spot locally, and tell the server without waiting (it may be unreachable).
            Downloads.shared.savePosition(item.id, seconds: pos)
            let client = client, id = item.id
            Task { await client.report(.stopped, itemId: id, plan: plan, positionSeconds: pos, isPaused: true) }
            return
        }
        await client.report(.stopped, itemId: item.id, plan: plan, positionSeconds: pos, isPaused: true)
        if plan.playMethod != "DirectPlay", let session = plan.playSessionId {
            await client.stopEncoding(playSessionId: session)
        }
    }

    // MARK: - Closing

    func close() {
        guard !finished else { return }
        finished = true
        controls.stop()
        sideSliders.restore()
        loadTask?.cancel()
        if controller.presentingViewController != nil {
            // Rotate once the player is gone: while it's on screen it only allows landscape, so iOS ignores the request.
            Orientation.allowed = .portrait
            controller.dismiss(animated: true) { Orientation.lock(.portrait) }
        } else {
            Orientation.lock(.portrait)
        }
        Task {
            await endStream()
            player.replaceCurrentItem(with: nil)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            onFinish?()   // after the stop report, so screens reload with the saved resume point
        }
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Can’t play this", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Close", style: .default) { [weak self] _ in self?.close() })
        let host: UIViewController? = controller.presentingViewController != nil ? controller : Player.topViewController()
        host?.present(alert, animated: true)
    }

    // MARK: - AVPlayerViewControllerDelegate

    // The player's close button / swipe-down ends playback, except when it's going into Picture in Picture.
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator) {
        // Back to portrait as the player leaves, so the screen underneath isn't shown sideways.
        if !inPictureInPicture { Orientation.lock(.portrait) }
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, !self.inPictureInPicture else { return }
            if context.isCancelled {
                Orientation.lock(.landscape)
            } else {
                self.close()
            }
        }
    }

    func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = true
    }

    func playerViewControllerDidStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
        Orientation.lock(.portrait)
    }

    func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
        inPictureInPicture = false
        if playerViewController.presentingViewController == nil { close() }
    }

    // Tapping "back to app" in Picture in Picture brings the full-screen player back.
    func playerViewController(_ playerViewController: AVPlayerViewController,
                              restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard playerViewController.presentingViewController == nil, let top = Player.topViewController() else {
            completionHandler(true)
            return
        }
        top.present(playerViewController, animated: true) {
            Orientation.lock(.landscape)
            completionHandler(true)
        }
    }
}
#endif
