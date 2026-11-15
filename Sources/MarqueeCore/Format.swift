import Foundation

public enum Format {
    public static let ticksPerSecond: Double = 10_000_000

    /// "52m" or "1h 52m".
    public static func runtime(_ ticks: Int64?) -> String? {
        guard let ticks, ticks > 0 else { return nil }
        let minutes = Int((Double(ticks) / ticksPerSecond / 60).rounded())
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// "S1:E3".
    public static func episodeLabel(_ item: Item) -> String? {
        guard let season = item.parentIndexNumber, let episode = item.indexNumber else { return nil }
        return "S\(season):E\(episode)"
    }

    /// Watched fraction, 0...1.
    public static func progress(_ item: Item) -> Double {
        if let pct = item.userData?.playedPercentage, pct > 0 { return min(pct / 100, 1) }
        guard let pos = item.userData?.playbackPositionTicks, let total = item.runTimeTicks, total > 0 else { return 0 }
        return min(Double(pos) / Double(total), 1)
    }

    /// Where to resume, in seconds: 0 when nothing was watched or it's past 95%.
    public static func resumeSeconds(_ item: Item) -> Double {
        let ticks = item.userData?.playbackPositionTicks ?? 0
        guard ticks > 0 else { return 0 }
        if let total = item.runTimeTicks, total > 0, Double(ticks) / Double(total) > 0.95 { return 0 }
        return Double(ticks) / ticksPerSecond
    }

    /// "2024 · 16+ · 1h 52m" / "2019 · 3 Seasons".
    public static func meta(_ item: Item) -> String {
        var parts: [String] = []
        if let year = item.productionYear { parts.append(String(year)) }
        if let rating = item.officialRating { parts.append(rating) }
        if item.isSeries, let n = item.childCount, n > 0 {
            parts.append(n == 1 ? "1 Season" : "\(n) Seasons")
        } else if let rt = runtime(item.runTimeTicks) {
            parts.append(rt)
        }
        return parts.joined(separator: " · ")
    }
}
