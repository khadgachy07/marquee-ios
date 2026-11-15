import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum JellyfinError: LocalizedError, Equatable {
    case http(Int)
    case badResponse
    case noPlayableSource
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .http(401): "Wrong username or password, or your sign-in has expired."
        case .http(let code): "The server answered with error \(code)."
        case .badResponse: "The server sent something unexpected."
        case .noPlayableSource: "This title has no playable version."
        case .server(let code): "Jellyfin couldn't play this (\(code))."
        }
    }
}

public enum PlaybackEvent: Sendable {
    case start, progress, stopped

    var path: String {
        switch self {
        case .start: "/Sessions/Playing"
        case .progress: "/Sessions/Playing/Progress"
        case .stopped: "/Sessions/Playing/Stopped"
        }
    }
}

/// Minimal Jellyfin API client (10.9+ routes). A value type: copy it, set `token`/`userId` after sign-in.
public struct JellyfinClient: Sendable {
    /// Base address, e.g. http://192.168.1.10:8096 or https://jellyfin.example.com (include any sub-path).
    public var server: URL
    public let deviceId: String
    public let deviceName: String
    public var token: String?
    public var userId: String?

    public static let clientName = "Marquee iOS"
    public static let version = "1.0"
    static let cardFields = "Overview,Genres,OfficialRating,CommunityRating,ProductionYear,RunTimeTicks,ChildCount"
    static let imageTypes = "Primary,Backdrop,Thumb,Logo"

    public init(server: URL, deviceId: String, deviceName: String, token: String? = nil, userId: String? = nil) {
        self.server = server
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.token = token
        self.userId = userId
    }

    /// Turns what someone types into a server URL: trims spaces, adds `http://` when no scheme is given,
    /// and drops trailing slashes. Nil unless it ends up an http(s) URL with a host.
    public static func serverURL(from text: String) -> URL? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - Plumbing

    public var authorizationHeader: String {
        var h = "MediaBrowser Client=\"\(Self.clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(Self.version)\""
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    var base: String {
        var s = server.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Absolute URL for an API path; nil query values are dropped. Keys are sorted so URLs are stable.
    public func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        var components = URLComponents(string: base + path)!
        let items = query.compactMap { pair in pair.value.map { URLQueryItem(name: pair.key, value: $0) } }
            .sorted { $0.name < $1.name }
        if !items.isEmpty { components.queryItems = (components.queryItems ?? []) + items }
        return components.url!
    }

    @discardableResult
    func send(_ method: String, _ path: String, query: [String: String?] = [:], body: JSON? = nil) async throws -> Data {
        var request = URLRequest(url: url(path, query))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw JellyfinError.http(http.statusCode) }
        return data
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String?] = [:]) async throws -> T {
        try JSONCoding.decoder().decode(T.self, from: try await send("GET", path, query: query))
    }

    private var cardQuery: [String: String?] {
        ["userId": userId, "fields": Self.cardFields, "enableImageTypes": Self.imageTypes, "imageTypeLimit": "1"]
    }

    // MARK: - Server and sign-in

    public func publicInfo() async throws -> PublicSystemInfo { try await get("/System/Info/Public") }
    public func publicUsers() async throws -> [UserDto] { try await get("/Users/Public") }

    public func authenticate(username: String, password: String) async throws -> AuthResult {
        let data = try await send("POST", "/Users/AuthenticateByName", body: ["Username": .string(username), "Pw": .string(password)])
        return try JSONCoding.decoder().decode(AuthResult.self, from: data)
    }

    public func logout() async {
        _ = try? await send("POST", "/Sessions/Logout")
    }

    // MARK: - Library

    public func views() async throws -> [Item] {
        let result: ItemsResult = try await get("/UserViews", ["userId": userId])
        return result.items
    }

    public func items(_ query: [String: String?]) async throws -> ItemsResult {
        var q = cardQuery
        q["recursive"] = "true"
        q.merge(query) { _, new in new }
        return try await get("/Items", q)
    }

    public func item(_ id: String) async throws -> Item {
        try await get("/Items/\(id)", ["userId": userId, "fields": Self.cardFields + ",Taglines,People"])
    }

    public func latest(parentId: String, limit: Int = 24) async throws -> [Item] {
        var q = cardQuery
        q["parentId"] = parentId
        q["limit"] = String(limit)
        q["groupItems"] = "true"
        return try await get("/Items/Latest", q)
    }

    public func resume(limit: Int = 20) async throws -> [Item] {
        var q = cardQuery
        q["limit"] = String(limit)
        q["mediaTypes"] = "Video"
        let result: ItemsResult = try await get("/UserItems/Resume", q)
        return result.items
    }

    public func nextUp(seriesId: String? = nil, limit: Int = 20) async throws -> [Item] {
        var q = cardQuery
        q["limit"] = String(limit)
        q["seriesId"] = seriesId
        q["enableResumable"] = "false"
        let result: ItemsResult = try await get("/Shows/NextUp", q)
        return result.items
    }

    public func seasons(seriesId: String) async throws -> [Item] {
        let result: ItemsResult = try await get("/Shows/\(seriesId)/Seasons", ["userId": userId, "fields": "ChildCount"])
        return result.items
    }

    public func episodes(seriesId: String, seasonId: String?) async throws -> [Item] {
        let result: ItemsResult = try await get("/Shows/\(seriesId)/Episodes", [
            "userId": userId, "seasonId": seasonId, "fields": "Overview,RunTimeTicks",
            "enableImageTypes": "Primary,Backdrop,Thumb", "imageTypeLimit": "1",
        ])
        return result.items
    }

    public func nextEpisode(after episode: Item) async throws -> Item? {
        guard let seriesId = episode.seriesId else { return nil }
        let result: ItemsResult = try await get("/Shows/\(seriesId)/Episodes", [
            "userId": userId, "startItemId": episode.id, "limit": "2", "fields": "Overview,RunTimeTicks",
        ])
        return result.items.first { $0.id != episode.id }
    }

    public func similar(_ id: String, limit: Int = 12) async throws -> [Item] {
        var q = cardQuery
        q["limit"] = String(limit)
        let result: ItemsResult = try await get("/Items/\(id)/Similar", q)
        return result.items
    }

    public func search(_ term: String) async throws -> [Item] {
        try await items(["searchTerm": term, "includeItemTypes": "Movie,Series,BoxSet", "limit": "50", "sortBy": "SortName"]).items
    }

    public func favorites() async throws -> [Item] {
        try await items(["isFavorite": "true", "includeItemTypes": "Movie,Series,BoxSet",
                         "sortBy": "DateCreated", "sortOrder": "Descending", "limit": "100"]).items
    }

    public func setFavorite(_ id: String, _ favorite: Bool) async throws {
        try await send(favorite ? "POST" : "DELETE", "/UserFavoriteItems/\(id)", query: ["userId": userId])
    }

    /// Marks a movie, episode, season or whole show as watched (or not). Unwatching also clears the resume point.
    public func setPlayed(_ id: String, _ played: Bool) async throws {
        try await send(played ? "POST" : "DELETE", "/UserPlayedItems/\(id)", query: ["userId": userId])
    }

    /// Drops the resume point, which takes the title off "Continue Watching" without marking it watched.
    public func clearResume(_ id: String) async throws {
        try await send("POST", "/UserItems/\(id)/UserData", query: ["userId": userId], body: .object(["PlaybackPositionTicks": 0]))
    }

    /// The episode (or first collection title) to start when someone presses Play on a show or collection.
    public func playableItem(for item: Item) async throws -> Item {
        switch item.type {
        case "Series":
            if let next = try await nextUp(seriesId: item.id, limit: 1).first { return next }
            if let first = try await items(["parentId": item.id, "includeItemTypes": "Episode",
                                            "sortBy": "ParentIndexNumber,IndexNumber", "limit": "1"]).items.first { return first }
            throw JellyfinError.noPlayableSource
        case "Season":
            if let first = try await items(["parentId": item.id, "includeItemTypes": "Episode",
                                            "sortBy": "IndexNumber", "limit": "1"]).items.first { return first }
            throw JellyfinError.noPlayableSource
        case "BoxSet":
            if let first = try await items(["parentId": item.id, "recursive": "false",
                                            "sortBy": "ProductionYear,SortName", "limit": "1"]).items.first {
                return try await self.item(first.id)
            }
            throw JellyfinError.noPlayableSource
        default:
            return item
        }
    }

    // MARK: - Images (Jellyfin serves these without a sign-in)

    public func imageURL(_ itemId: String, _ type: String, tag: String?, maxWidth: Int, index: Int? = nil) -> URL {
        let path = index.map { "/Items/\(itemId)/Images/\(type)/\($0)" } ?? "/Items/\(itemId)/Images/\(type)"
        return url(path, ["maxWidth": String(maxWidth), "quality": "90", "tag": tag])
    }

    public func userImageURL(_ user: UserDto, size: Int = 240) -> URL? {
        user.primaryImageTag.map { url("/Users/\(user.id)/Images/Primary", ["fillWidth": String(size), "fillHeight": String(size), "tag": $0]) }
    }

    /// Best 16:9 artwork for a card.
    public func landscapeURL(_ item: Item, width: Int = 560) -> URL? {
        if item.isEpisode {
            if let tag = item.imageTag("Primary") { return imageURL(item.id, "Primary", tag: tag, maxWidth: width) }
            if let id = item.parentThumbItemId { return imageURL(id, "Thumb", tag: item.parentThumbImageTag, maxWidth: width) }
        }
        if let tag = item.imageTag("Thumb") { return imageURL(item.id, "Thumb", tag: tag, maxWidth: width) }
        if let tag = item.backdropImageTags?.first { return imageURL(item.id, "Backdrop", tag: tag, maxWidth: width, index: 0) }
        if let id = item.parentBackdropItemId {
            return imageURL(id, "Backdrop", tag: item.parentBackdropImageTags?.first, maxWidth: width, index: 0)
        }
        if let tag = item.imageTag("Primary") { return imageURL(item.id, "Primary", tag: tag, maxWidth: width) }
        return nil
    }

    /// Portrait art. An episode's own image is a wide still, so episodes use their show's poster.
    public func posterURL(_ item: Item, width: Int = 360) -> URL? {
        if item.isEpisode, let id = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(id, "Primary", tag: tag, maxWidth: width)
        }
        if let tag = item.imageTag("Primary") { return imageURL(item.id, "Primary", tag: tag, maxWidth: width) }
        if let id = item.seriesId, let tag = item.seriesPrimaryImageTag { return imageURL(id, "Primary", tag: tag, maxWidth: width) }
        return nil
    }

    public func backdropURL(_ item: Item, width: Int = 1280) -> URL? {
        if let tag = item.backdropImageTags?.first { return imageURL(item.id, "Backdrop", tag: tag, maxWidth: width, index: 0) }
        if let id = item.parentBackdropItemId {
            return imageURL(id, "Backdrop", tag: item.parentBackdropImageTags?.first, maxWidth: width, index: 0)
        }
        return landscapeURL(item, width: width)
    }

    public func logoURL(_ item: Item, width: Int = 600) -> URL? {
        if let tag = item.imageTag("Logo") { return imageURL(item.id, "Logo", tag: tag, maxWidth: width) }
        if let id = item.parentLogoItemId { return imageURL(id, "Logo", tag: item.parentLogoImageTag, maxWidth: width) }
        return nil
    }

    // MARK: - Playback

    /// `allowDirectPlay: false` makes Jellyfin answer with HLS (copying the video/audio when the device can play them).
    public func playbackInfo(itemId: String, profile: JSON, subtitleIndex: Int? = nil,
                             maxBitrate: Int = 120_000_000, allowDirectPlay: Bool = true) async throws -> PlaybackInfoResponse {
        var body: [String: JSON] = [
            "UserId": .string(userId ?? ""), "DeviceProfile": profile, "MaxStreamingBitrate": .int(maxBitrate),
            // The player seeks to the resume point itself, so the stream always starts at 0.
            "StartTimeTicks": 0,
            "EnableDirectPlay": .bool(allowDirectPlay), "EnableDirectStream": .bool(allowDirectPlay), "EnableTranscoding": true,
            "AllowVideoStreamCopy": true, "AllowAudioStreamCopy": true, "AutoOpenLiveStream": true,
        ]
        if let subtitleIndex { body["SubtitleStreamIndex"] = .int(subtitleIndex) }
        let data = try await send("POST", "/Items/\(itemId)/PlaybackInfo", query: ["userId": userId], body: .object(body))
        return try JSONCoding.decoder().decode(PlaybackInfoResponse.self, from: data)
    }

    /// Turns Jellyfin's PlaybackInfo answer into the URL AVPlayer should open.
    public func plan(for itemId: String, _ info: PlaybackInfoResponse) throws -> PlaybackPlan {
        if let code = info.errorCode { throw JellyfinError.server(code) }
        guard let source = info.mediaSources?.first else { throw JellyfinError.noPlayableSource }

        if source.supportsDirectPlay == true {
            let streamURL = originalFileURL(itemId, source, playSessionId: info.playSessionId)
            return PlaybackPlan(url: streamURL, playMethod: "DirectPlay", playSessionId: info.playSessionId, mediaSourceId: source.id)
        }
        if let path = source.transcodingUrl {
            guard let streamURL = transcodingURL(path) else { throw JellyfinError.badResponse }
            let method = path.contains("TranscodeReasons=") ? "Transcode" : "DirectStream"
            return PlaybackPlan(url: streamURL, playMethod: method, playSessionId: info.playSessionId, mediaSourceId: source.id)
        }
        throw JellyfinError.noPlayableSource
    }

    /// Jellyfin's relative TranscodingUrl made absolute, with the token unless the server already put one in.
    private func transcodingURL(_ path: String) -> URL? {
        var full = path.hasPrefix("http") ? path : base + path
        let lower = full.lowercased()
        if !lower.contains("api_key=") && !lower.contains("apikey="), let token {
            full += (full.contains("?") ? "&" : "?") + "api_key=" + token
        }
        return URL(string: full)
    }

    /// A subtitle stream as WebVTT, whatever format the file has it in (text subtitles only).
    public func subtitleURL(itemId: String, mediaSourceId: String, index: Int) -> URL {
        url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/0/Stream.vtt", ["api_key": token])
    }

    public func subtitleCues(itemId: String, mediaSourceId: String, index: Int) async throws -> [SubtitleCue] {
        let data = try await data(from: subtitleURL(itemId: itemId, mediaSourceId: mediaSourceId, index: index), timeout: 30)
        return Subtitles.parseVTT(String(decoding: data, as: UTF8.self))
    }

    // MARK: - Downloads

    /// GET with this client's sign-in, for HLS playlists and segments. Long timeout: Jellyfin answers a segment
    /// request only once it has made that segment.
    public func data(from url: URL, timeout: TimeInterval = 90) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.badResponse }
        guard (200..<300).contains(http.statusCode) else { throw JellyfinError.http(http.statusCode) }
        return data
    }

    /// The segment list of the HLS stream in `info` (ask with `allowDirectPlay: false`). Downloads fetch these one by one
    /// into a single fragmented MP4, so they can pause between segments and play whatever has arrived.
    public func downloadPlaylist(_ info: PlaybackInfoResponse) async throws -> HLSPlaylist {
        if let code = info.errorCode { throw JellyfinError.server(code) }
        guard let path = info.mediaSources?.first?.transcodingUrl, var url = transcodingURL(path) else {
            throw JellyfinError.noPlayableSource
        }
        var text = String(decoding: try await data(from: url), as: UTF8.self)
        if let variant = HLS.variantURL(in: text, base: url) {
            url = variant
            text = String(decoding: try await data(from: url), as: UTF8.self)
        }
        let playlist = HLS.mediaPlaylist(text, base: url)
        // A file of joined segments only plays if they're fragmented MP4 (with an init segment), not MPEG-TS.
        guard playlist.initURL != nil, !playlist.segments.isEmpty else { throw JellyfinError.noPlayableSource }
        return playlist
    }

    /// The file exactly as Jellyfin stores it.
    private func originalFileURL(_ itemId: String, _ source: MediaSource, playSessionId: String?) -> URL {
        let ext = source.container?.split(separator: ",").first.map(String.init) ?? "mp4"
        return url("/Videos/\(itemId)/stream.\(ext)", [
            "static": "true", "mediaSourceId": source.id, "deviceId": deviceId,
            "api_key": token, "Tag": source.eTag, "PlaySessionId": playSessionId,
        ])
    }

    /// Start / progress / stop reports, so Jellyfin keeps resume points and "Continue Watching" up to date.
    public func report(_ event: PlaybackEvent, itemId: String, plan: PlaybackPlan, positionSeconds: Double, isPaused: Bool) async {
        var body: [String: JSON] = [
            "ItemId": .string(itemId), "MediaSourceId": .string(plan.mediaSourceId),
            "PositionTicks": .int(Int(max(0, positionSeconds) * Format.ticksPerSecond)),
            "IsPaused": .bool(isPaused), "PlayMethod": .string(plan.playMethod), "CanSeek": true,
        ]
        if let session = plan.playSessionId { body["PlaySessionId"] = .string(session) }
        _ = try? await send("POST", event.path, body: .object(body))
    }

    public func stopEncoding(playSessionId: String) async {
        _ = try? await send("DELETE", "/Videos/ActiveEncodings", query: ["deviceId": deviceId, "playSessionId": playSessionId])
    }
}
