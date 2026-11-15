import Foundation

/// What Apple's player (AVPlayer) can play, so Jellyfin sends files as-is when it can and
/// otherwise repackages or converts them into HLS.
public enum DeviceProfile {
    public static func avPlayer(maxBitrate: Int = 120_000_000) -> JSON {
        let rangeTypes = "SDR|HDR10|HDR10Plus|HLG|DOVI|DOVIWithHDR10|DOVIWithHLG|DOVIWithSDR"
        return [
            "Name": "Marquee iOS",
            "MaxStreamingBitrate": .int(maxBitrate),
            "MaxStaticBitrate": .int(maxBitrate),
            "MusicStreamingTranscodingBitrate": 384_000,
            "DirectPlayProfiles": [
                // AVPlayer can't open MKV, so those always go through HLS (usually a cheap stream copy).
                ["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3,ac3,eac3,alac,flac"],
                ["Container": "mp3", "Type": "Audio"],
                ["Container": "aac,m4a", "Type": "Audio", "AudioCodec": "aac,alac"],
            ],
            "TranscodingProfiles": [
                // fMP4 HLS lets Jellyfin copy HEVC instead of re-encoding it; Apple's HLS handles any keyframe type.
                ["Container": "mp4", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
                 "VideoCodec": "hevc,h264", "AudioCodec": "aac,ac3,eac3,mp3",
                 "MaxAudioChannels": "6", "MinSegments": 1, "BreakOnNonKeyFrames": true],
                ["Container": "ts", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
                 "VideoCodec": "h264", "AudioCodec": "aac,mp3", "MaxAudioChannels": "6", "MinSegments": 1],
                ["Container": "mp3", "Type": "Audio", "AudioCodec": "mp3", "Context": "Streaming", "Protocol": "http", "MaxAudioChannels": "2"],
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [
                ["Type": "Video", "Codec": "h264", "Conditions": [
                    ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "high|main|baseline|constrained baseline", "IsRequired": false],
                    ["Condition": "LessThanEqual", "Property": "VideoLevel", "Value": "52", "IsRequired": false],
                    ["Condition": "NotEquals", "Property": "IsInterlaced", "Value": "true", "IsRequired": false],
                ]],
                ["Type": "Video", "Codec": "hevc", "Conditions": [
                    ["Condition": "EqualsAny", "Property": "VideoProfile", "Value": "main|main 10", "IsRequired": false],
                    ["Condition": "EqualsAny", "Property": "VideoRangeType", "Value": .string(rangeTypes), "IsRequired": false],
                    ["Condition": "NotEquals", "Property": "IsInterlaced", "Value": "true", "IsRequired": false],
                ]],
            ],
            "SubtitleProfiles": [
                // Text subtitles stay out of the stream: the app fetches them separately and draws them itself
                // (one menu for streams and downloads alike). Picture ones are drawn in by the server when picked.
                ["Format": "vtt", "Method": "External"],
                ["Format": "webvtt", "Method": "External"],
                ["Format": "mov_text", "Method": "Embed"],
                ["Format": "pgssub", "Method": "Encode"],
                ["Format": "dvdsub", "Method": "Encode"],
                ["Format": "dvbsub", "Method": "Encode"],
            ],
            "ResponseProfiles": [["Type": "Video", "Container": "m4v", "MimeType": "video/mp4"]],
        ]
    }
}
