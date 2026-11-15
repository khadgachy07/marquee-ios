import Foundation

/// Joins Jellyfin's fragmented-MP4 HLS segments into one file AVPlayer can play.
///
/// Each segment arrives as `styp`, `sidx`, `moof`, `mdat`. Appending them as-is plays only up to the first point where
/// Jellyfin restarted its conversion (after a paused download resumes): fragment numbers start again at 1 there and
/// AVPlayer stops reading. So this keeps only the `moof`/`mdat` pairs, numbers fragments 1, 2, 3… across restarts,
/// and drops fragments that repeat time already in the file (Jellyfin re-sends the end when it restarts for the last
/// segment). The init segment (`ftyp` + `moov`) is written once, unchanged. Codable so a resumed download carries on.
public struct FMP4Joiner: Codable, Sendable, Equatable {
    public private(set) var sequence: UInt32 = 0
    /// Decode time of the last fragment written, in its track's units (the first track of each fragment).
    public private(set) var lastStart: UInt64?

    public init() {}

    /// The bytes to append to the file for one media segment (possibly empty, if it was all repeats).
    public mutating func append(_ segment: Data) -> Data {
        let bytes = [UInt8](segment)
        let boxes = Self.boxes(bytes, in: 0..<bytes.count)
        var out = Data()
        var index = 0
        while index < boxes.count {
            guard boxes[index].type == "moof", index + 1 < boxes.count, boxes[index + 1].type == "mdat" else {
                index += 1
                continue
            }
            var moof = Array(bytes[boxes[index].range])
            let mdat = bytes[boxes[index + 1].range]
            index += 2
            let start = Self.firstDecodeTime(moof)
            if let start, let lastStart, start <= lastStart { continue }   // already in the file
            sequence += 1
            Self.setSequence(&moof, sequence)
            out.append(contentsOf: moof)
            out.append(contentsOf: mdat)
            if let start { lastStart = start }
        }
        return out
    }

    // MARK: - Box reading

    struct Box {
        let type: String
        /// The whole box, header included.
        let range: Range<Int>
        let headerSize: Int
        var payload: Range<Int> { (range.lowerBound + headerSize)..<range.upperBound }
    }

    static func boxes(_ bytes: [UInt8], in range: Range<Int>) -> [Box] {
        var result: [Box] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            var size = Int(u32(bytes, pos))
            var header = 8
            if size == 1, pos + 16 <= range.upperBound {
                size = Int(u64(bytes, pos + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - pos
            }
            guard size >= header, pos + size <= range.upperBound else { break }
            let type = String(decoding: bytes[(pos + 4)..<(pos + 8)], as: UTF8.self)
            result.append(Box(type: type, range: pos..<(pos + size), headerSize: header))
            pos += size
        }
        return result
    }

    /// `tfdt` base media decode time of the first `traf` in a `moof`.
    static func firstDecodeTime(_ moof: [UInt8]) -> UInt64? {
        guard let moofBox = boxes(moof, in: 0..<moof.count).first,
              let traf = boxes(moof, in: moofBox.payload).first(where: { $0.type == "traf" }),
              let tfdt = boxes(moof, in: traf.payload).first(where: { $0.type == "tfdt" }) else { return nil }
        let at = tfdt.payload.lowerBound
        return moof[at] == 1 ? u64(moof, at + 4) : UInt64(u32(moof, at + 4))
    }

    /// Writes the `mfhd` sequence number of a `moof`.
    static func setSequence(_ moof: inout [UInt8], _ value: UInt32) {
        guard let moofBox = boxes(moof, in: 0..<moof.count).first,
              let mfhd = boxes(moof, in: moofBox.payload).first(where: { $0.type == "mfhd" }) else { return }
        let at = mfhd.payload.lowerBound + 4   // after version and flags
        for i in 0..<4 { moof[at + i] = UInt8(truncatingIfNeeded: value >> (24 - 8 * i)) }
    }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 << 8 | UInt32(b[at + $1]) }
    }

    static func u64(_ b: [UInt8], _ at: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 << 8 | UInt64(b[at + $1]) }
    }
}
