import Foundation

/// One subtitle line, shown from `start` to `end` (seconds).
public struct SubtitleCue: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let text: String
}

/// Subtitles the app draws itself, from WebVTT (Jellyfin converts SRT, ASS and the rest to it).
public enum Subtitles {
    /// The language the player picks when the viewer asks for subtitles without naming one.
    public static let preferredLanguage = "eng"

    public static func parseVTT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            let body = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: "\n")
            if !body.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// The text showing at `time`, or nil. `cues` must be sorted by start (as `parseVTT` returns them).
    public static func text(at time: Double, in cues: [SubtitleCue]) -> String? {
        // Last cue starting at or before `time`, then any earlier ones that still overlap it.
        var low = 0, high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        var lines: [String] = []
        var i = low - 1
        while i >= 0, i >= low - 4 {
            if cues[i].end > time { lines.insert(cues[i].text, at: 0) }
            i -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// The subtitle to show for a language: text before pictures, the file's default, then plain before SDH/forced.
    public static func pick(_ language: String, from streams: [MediaStream]) -> MediaStream? {
        let subtitles = streams.filter(\.isSubtitle)
        var matches = subtitles.filter { $0.languageCode == language }
        // Files often leave the language out; with a single untagged track, take that for the preferred language.
        if matches.isEmpty, language == preferredLanguage {
            matches = subtitles.filter { $0.languageCode == nil }
        }
        return matches.min { rank($0) < rank($1) }
    }

    private static func rank(_ s: MediaStream) -> Int {
        (s.isText ? 0 : 8) + (s.isForced == true ? 4 : 0) + (s.isHearingImpaired == true ? 2 : 0) + (s.isDefault == true ? 0 : 1)
    }

    /// A short menu name: "English", "English (SDH)", "Spanish 2".
    public static func names(for streams: [MediaStream], locale: Locale = Locale(identifier: "en")) -> [Int: String] {
        var names: [Int: String] = [:]
        var seen: [String: Int] = [:]
        for s in streams {
            var name = s.languageCode.flatMap { locale.localizedString(forLanguageCode: $0) } ?? "Unknown language"
            if s.isHearingImpaired == true { name += " (SDH)" }
            if s.isForced == true { name += " (Forced)" }
            seen[name, default: 0] += 1
            names[s.index] = seen[name]! > 1 ? "\(name) \(seen[name]!)" : name
        }
        return names
    }

    /// "00:01:02.345" or "01:02.345" → seconds.
    static func seconds(_ stamp: String) -> Double? {
        let fields = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(fields.count) else { return nil }
        var total = 0.0
        for field in fields {
            guard let value = Double(field) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "{\\\\[^}]*}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
