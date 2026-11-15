import Foundation

// Jellyfin's JSON uses PascalCase keys ("ServerName"); `JSONCoding.decoder()` lowercases the first letter
// so these camelCase properties line up. Only the fields the app uses are declared.

public struct PublicSystemInfo: Codable, Sendable {
    public let serverName: String?
    public let version: String?
    public let id: String?
}

public struct UserDto: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let primaryImageTag: String?
    public let hasPassword: Bool?
    public let hasConfiguredPassword: Bool?

    public init(id: String, name: String, primaryImageTag: String? = nil, hasPassword: Bool? = nil, hasConfiguredPassword: Bool? = nil) {
        self.id = id
        self.name = name
        self.primaryImageTag = primaryImageTag
        self.hasPassword = hasPassword
        self.hasConfiguredPassword = hasConfiguredPassword
    }

    /// Public user list entries say whether a password is needed.
    public var needsPassword: Bool { (hasPassword ?? true) || (hasConfiguredPassword ?? false) }
}

public struct AuthResult: Codable, Sendable {
    public let accessToken: String
    public let user: UserDto
}

public struct UserData: Codable, Sendable, Hashable {
    public var playbackPositionTicks: Int64?
    public var playedPercentage: Double?
    public var played: Bool?
    public var isFavorite: Bool?
}

public struct Item: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String?
    public let type: String?
    public let seriesId: String?
    public let seriesName: String?
    public let seasonId: String?
    public let parentIndexNumber: Int?
    public let indexNumber: Int?
    public let overview: String?
    public let productionYear: Int?
    public let officialRating: String?
    public let communityRating: Double?
    public let runTimeTicks: Int64?
    public let imageTags: [String: String]?
    public let backdropImageTags: [String]?
    public let parentBackdropItemId: String?
    public let parentBackdropImageTags: [String]?
    public let parentThumbItemId: String?
    public let parentThumbImageTag: String?
    public let parentLogoItemId: String?
    public let parentLogoImageTag: String?
    public let seriesPrimaryImageTag: String?
    public let genres: [String]?
    public let childCount: Int?
    public let collectionType: String?
    public var userData: UserData?

    public var isEpisode: Bool { type == "Episode" }
    public var isSeries: Bool { type == "Series" }

    /// Image tag by type ("Primary", "Thumb", "Logo"). JSONDecoder may apply the key strategy to
    /// dictionary keys too, so accept both spellings.
    public func imageTag(_ type: String) -> String? {
        imageTags?[type] ?? imageTags?[JSONCoding.lowerFirst(type)]
    }
}

public struct ItemsResult: Codable, Sendable {
    public let items: [Item]
    public let totalRecordCount: Int?
}

public struct MediaSource: Codable, Sendable, Hashable {
    public let id: String
    public let container: String?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let transcodingUrl: String?
    public let eTag: String?
    public let mediaStreams: [MediaStream]?
    public let defaultAudioStreamIndex: Int?
    public let defaultSubtitleStreamIndex: Int?
}

/// One audio, video or subtitle stream of a file, as Jellyfin numbers them (`index` is what playback requests use).
public struct MediaStream: Codable, Sendable, Hashable {
    public let index: Int
    public let type: String?
    public let language: String?
    public let title: String?
    public let displayTitle: String?
    public let codec: String?
    public let isDefault: Bool?
    public let isForced: Bool?
    public let isExternal: Bool?
    public let isHearingImpaired: Bool?
    /// False for picture subtitles (PGS, DVD), which only the server can show, by drawing them into the video.
    public let isTextSubtitleStream: Bool?

    public init(index: Int, type: String?, language: String?, title: String? = nil, displayTitle: String? = nil,
                codec: String? = nil, isDefault: Bool? = nil, isForced: Bool? = nil, isExternal: Bool? = nil,
                isHearingImpaired: Bool? = nil, isTextSubtitleStream: Bool? = nil) {
        self.index = index
        self.type = type
        self.language = language
        self.title = title
        self.displayTitle = displayTitle
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.isExternal = isExternal
        self.isHearingImpaired = isHearingImpaired
        self.isTextSubtitleStream = isTextSubtitleStream
    }

    public var isSubtitle: Bool { type == "Subtitle" }
    public var isText: Bool { isTextSubtitleStream ?? false }
    /// Three-letter code ("eng"), or nil when the file doesn't say.
    public var languageCode: String? {
        guard let code = language?.lowercased(), !code.isEmpty, code != "und", code != "unk" else { return nil }
        return code == "en" ? "eng" : code
    }
}

public struct PlaybackInfoResponse: Codable, Sendable {
    public let mediaSources: [MediaSource]?
    public let playSessionId: String?
    public let errorCode: String?
}

/// What the player should open: a URL plus the ids Jellyfin wants in progress reports.
public struct PlaybackPlan: Sendable, Equatable {
    public let url: URL
    /// "DirectPlay", "DirectStream" or "Transcode", as Jellyfin's session reports expect.
    public let playMethod: String
    public let playSessionId: String?
    public let mediaSourceId: String

    /// A downloaded file; reported to Jellyfin as direct play of the item's own media source.
    public static func downloaded(_ file: URL, itemId: String) -> PlaybackPlan {
        PlaybackPlan(url: file, playMethod: "DirectPlay", playSessionId: nil, mediaSourceId: itemId)
    }
}
