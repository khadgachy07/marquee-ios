import Foundation

/// A media playlist: the fMP4 init segment and the media segments, with their lengths.
public struct HLSPlaylist: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public let url: URL
        public let duration: Double
    }

    public var initURL: URL?
    public var segments: [Segment]

    public var duration: Double { segments.reduce(0) { $0 + $1.duration } }
}

/// Just enough HLS playlist reading for Jellyfin's streams.
public enum HLS {
    /// The first variant of a master playlist, or nil when `text` is already a media playlist.
    public static func variantURL(in text: String, base: URL) -> URL? {
        let lines = lines(text)
        guard let tag = lines.firstIndex(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }),
              let uri = lines[(tag + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { return nil }
        return resolve(uri, base)
    }

    public static func mediaPlaylist(_ text: String, base: URL) -> HLSPlaylist {
        var playlist = HLSPlaylist(initURL: nil, segments: [])
        var pendingDuration: Double?
        for line in lines(text) {
            if line.hasPrefix("#EXT-X-MAP:"), let uri = attribute("URI", in: line) {
                playlist.initURL = resolve(uri, base)
            } else if line.hasPrefix("#EXTINF:") {
                pendingDuration = line.dropFirst("#EXTINF:".count).split(separator: ",").first.flatMap { Double($0) }
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration, let url = resolve(line, base) {
                playlist.segments.append(.init(url: url, duration: duration))
                pendingDuration = nil
            }
        }
        return playlist
    }

    /// A master playlist marked as having no closed captions (AVPlayer otherwise assumes there may be some and shows
    /// its own subtitles button), with every address made absolute so it can be loaded from anywhere.
    public static func withoutClosedCaptions(_ text: String, base: URL) -> String {
        lines(text).map { line in
            if line.hasPrefix("#EXT-X-STREAM-INF:"), !line.contains("CLOSED-CAPTIONS=") {
                return line + ",CLOSED-CAPTIONS=NONE"
            }
            if !line.isEmpty, !line.hasPrefix("#"), let url = resolve(line, base) { return url.absoluteString }
            return line
        }.joined(separator: "\n") + "\n"
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func resolve(_ uri: String, _ base: URL) -> URL? {
        URL(string: uri, relativeTo: base)?.absoluteURL
    }

    /// `URI="..."` style attribute value.
    private static func attribute(_ name: String, in line: String) -> String? {
        guard let start = line.range(of: name + "=\"") else { return nil }
        let rest = line[start.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }
}
