import Foundation
import XCTest
@testable import MarqueeCore

final class MarqueeCoreTests: XCTestCase {
    let client = JellyfinClient(server: URL(string: "http://jf.test:8099/jellyfin/")!, deviceId: "dev1",
                                deviceName: "iPhone", token: "tok", userId: "u1")

    func testDecodesPascalCaseItems() throws {
        let json = """
        {"Items":[{"Id":"e1","Name":"Matinee","Type":"Episode","SeriesId":"s1","SeriesName":"Wonder Man",
          "ParentIndexNumber":1,"IndexNumber":1,"RunTimeTicks":18000000000,
          "ImageTags":{"Primary":"ptag"},"BackdropImageTags":[],"ParentBackdropItemId":"s1",
          "UserData":{"PlaybackPositionTicks":1130000000,"Played":false,"IsFavorite":true}}],
         "TotalRecordCount":1}
        """
        let result = try JSONCoding.decoder().decode(ItemsResult.self, from: Data(json.utf8))
        let ep = try XCTUnwrap(result.items.first)
        XCTAssertEqual(ep.seriesName, "Wonder Man")
        XCTAssertTrue(ep.isEpisode)
        XCTAssertEqual(ep.imageTag("Primary"), "ptag")
        XCTAssertEqual(ep.userData?.isFavorite, true)
        XCTAssertEqual(Format.resumeSeconds(ep), 113, accuracy: 0.01)
        XCTAssertEqual(Format.episodeLabel(ep), "S1:E1")
        XCTAssertEqual(Format.runtime(ep.runTimeTicks), "30m")
    }

    func testDecodesAuthResult() throws {
        let json = #"{"AccessToken":"abc","User":{"Id":"u1","Name":"Me","HasPassword":true,"HasConfiguredPassword":true}}"#
        let auth = try JSONCoding.decoder().decode(AuthResult.self, from: Data(json.utf8))
        XCTAssertEqual(auth.accessToken, "abc")
        XCTAssertEqual(auth.user.name, "Me")
        XCTAssertTrue(auth.user.needsPassword)
    }

    func testURLBuildingDropsNilsAndTrailingSlash() {
        let u = client.url("/Items", ["b": "2", "a": "1", "skip": nil])
        XCTAssertEqual(u.absoluteString, "http://jf.test:8099/jellyfin/Items?a=1&b=2")
    }

    func testDirectPlayPlan() throws {
        let json = #"{"MediaSources":[{"Id":"ms1","Container":"mov,mp4,m4a","SupportsDirectPlay":true,"ETag":"et"}],"PlaySessionId":"ps1"}"#
        let info = try JSONCoding.decoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
        let plan = try client.plan(for: "i1", info)
        XCTAssertEqual(plan.playMethod, "DirectPlay")
        XCTAssertEqual(plan.url.path, "/jellyfin/Videos/i1/stream.mov")
        XCTAssertTrue(plan.url.query?.contains("api_key=tok") == true)
        XCTAssertEqual(plan.playSessionId, "ps1")
    }

    func testHLSPlanKeepsServerApiKey() throws {
        let json = #"{"MediaSources":[{"Id":"ms1","SupportsDirectPlay":false,"TranscodingUrl":"/videos/i1/master.m3u8?VideoCodec=hevc&ApiKey=srv&TranscodeReasons=ContainerNotSupported"}],"PlaySessionId":"ps1"}"#
        let info = try JSONCoding.decoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
        let plan = try client.plan(for: "i1", info)
        XCTAssertEqual(plan.playMethod, "Transcode")
        XCTAssertEqual(plan.url.absoluteString, "http://jf.test:8099/jellyfin/videos/i1/master.m3u8?VideoCodec=hevc&ApiKey=srv&TranscodeReasons=ContainerNotSupported")
    }

    func testPlanErrors() throws {
        let info = try JSONCoding.decoder().decode(PlaybackInfoResponse.self, from: Data(#"{"ErrorCode":"NoCompatibleStream"}"#.utf8))
        XCTAssertThrowsError(try client.plan(for: "i1", info)) { XCTAssertEqual($0 as? JellyfinError, .server("NoCompatibleStream")) }
    }

    func testReadsJellyfinHLSPlaylists() throws {
        let master = URL(string: "http://jf.test:8099/jellyfin/videos/i1/master.m3u8?ApiKey=srv&PlaySessionId=ps1")!
        let masterText = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="hvc1.2.4.L120,mp4a.40.2"
        main.m3u8?ApiKey=srv&PlaySessionId=ps1
        """
        let main = try XCTUnwrap(HLS.variantURL(in: masterText, base: master))
        XCTAssertEqual(main.absoluteString, "http://jf.test:8099/jellyfin/videos/i1/main.m3u8?ApiKey=srv&PlaySessionId=ps1")

        let mainText = """
        #EXTM3U
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:6
        #EXT-X-MAP:URI="hls1/main/-1.mp4?ApiKey=srv"
        #EXTINF:6.000000, nodesc
        hls1/main/0.mp4?ApiKey=srv
        #EXTINF:2.5, nodesc
        hls1/main/1.mp4?ApiKey=srv
        #EXT-X-ENDLIST
        """
        XCTAssertEqual(HLS.withoutClosedCaptions(masterText, base: master), """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=8000000,CODECS="hvc1.2.4.L120,mp4a.40.2",CLOSED-CAPTIONS=NONE
        http://jf.test:8099/jellyfin/videos/i1/main.m3u8?ApiKey=srv&PlaySessionId=ps1

        """)
        XCTAssertNil(HLS.variantURL(in: mainText, base: main))
        let playlist = HLS.mediaPlaylist(mainText, base: main)
        XCTAssertEqual(playlist.initURL?.absoluteString, "http://jf.test:8099/jellyfin/videos/i1/hls1/main/-1.mp4?ApiKey=srv")
        XCTAssertEqual(playlist.segments.map(\.url.lastPathComponent), ["0.mp4", "1.mp4"])
        XCTAssertEqual(playlist.duration, 8.5, accuracy: 0.001)
    }

    func testJoinerRenumbersAcrossRestartsAndSkipsRepeats() {
        func box(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let size = UInt32(8 + payload.count)
            return withUnsafeBytes(of: size.bigEndian, Array.init) + Array(type.utf8) + payload
        }
        func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
        // One HLS segment as Jellyfin sends it: styp, sidx, then a fragment with the given number and start time.
        func segment(seq: UInt32, start: UInt32, sample: UInt8) -> Data {
            let moof = box("moof", box("mfhd", [0, 0, 0, 0] + be32(seq))
                + box("traf", box("tfhd", [0, 2, 0, 0] + be32(1)) + box("tfdt", [0, 0, 0, 0] + be32(start))))
            return Data(box("styp", Array("msdh".utf8)) + box("sidx", [0, 0, 0, 0]) + moof + box("mdat", [sample]))
        }
        var joiner = FMP4Joiner()
        var file = Data()
        file += joiner.append(segment(seq: 1, start: 0, sample: 0xA))
        file += joiner.append(segment(seq: 2, start: 100, sample: 0xB))
        file += joiner.append(segment(seq: 1, start: 200, sample: 0xC))   // server restarted: numbering starts over
        file += joiner.append(segment(seq: 1, start: 150, sample: 0xD))   // repeat of time already written

        let bytes = [UInt8](file)
        let top = FMP4Joiner.boxes(bytes, in: 0..<bytes.count)
        XCTAssertEqual(top.map(\.type), ["moof", "mdat", "moof", "mdat", "moof", "mdat"])   // no styp/sidx, no repeat
        let moofs = top.filter { $0.type == "moof" }.map { Array(bytes[$0.range]) }
        XCTAssertEqual(moofs.map { FMP4Joiner.u32($0, 20) }, [1, 2, 3])   // mfhd sequence numbers
        XCTAssertEqual(moofs.compactMap(FMP4Joiner.firstDecodeTime), [0, 100, 200])
        XCTAssertEqual(top.filter { $0.type == "mdat" }.map { bytes[$0.range.upperBound - 1] }, [0xA, 0xB, 0xC])
        XCTAssertEqual(joiner.sequence, 3)
    }

    func testParsesVTTAndFindsCueAtTime() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.500 align:middle
        <i>Hello</i> there &amp; welcome

        00:01:02,250 --> 01:02:05.000
        Two
        lines

        00:01:03.000 --> 00:01:04.000
        Overlap
        """
        let cues = Subtitles.parseVTT(vtt)
        XCTAssertEqual(cues.count, 3)
        XCTAssertEqual(cues[0], SubtitleCue(start: 1, end: 3.5, text: "Hello there & welcome"))
        XCTAssertEqual(cues[1].start, 62.25, accuracy: 0.001)
        XCTAssertEqual(cues[1].end, 3725, accuracy: 0.001)
        XCTAssertNil(Subtitles.text(at: 0.5, in: cues))
        XCTAssertEqual(Subtitles.text(at: 2, in: cues), "Hello there & welcome")
        XCTAssertNil(Subtitles.text(at: 3.5, in: cues))
        XCTAssertEqual(Subtitles.text(at: 63.5, in: cues), "Two\nlines\nOverlap")
    }

    func testPicksEnglishSubtitle() throws {
        func sub(_ i: Int, _ lang: String?, text: Bool = true, def: Bool = false, sdh: Bool = false) -> MediaStream {
            MediaStream(index: i, type: "Subtitle", language: lang, isDefault: def, isHearingImpaired: sdh, isTextSubtitleStream: text)
        }
        // Wonder Man: only an SDH English track among many.
        XCTAssertEqual(Subtitles.pick("eng", from: [sub(2, "eng", sdh: true), sub(3, "ces"), sub(5, "deu")])?.index, 2)
        // Plain beats SDH, text beats pictures, the default wins a tie.
        XCTAssertEqual(Subtitles.pick("eng", from: [sub(1, "eng", sdh: true), sub(2, "eng"), sub(3, "eng", def: true)])?.index, 3)
        XCTAssertEqual(Subtitles.pick("eng", from: [sub(1, "eng", text: false, def: true), sub(2, "en")])?.index, 2)
        // Evil Dead: pictures only.
        XCTAssertEqual(Subtitles.pick("eng", from: [sub(2, "eng", text: false, def: true), sub(6, "ara", text: false)])?.index, 2)
        // Chernobyl: one track with no language.
        XCTAssertEqual(Subtitles.pick("eng", from: [sub(1, nil)])?.index, 1)
        XCTAssertNil(Subtitles.pick("eng", from: [sub(4, "hin")]))
        XCTAssertNil(Subtitles.pick("fra", from: [sub(1, nil)]))

        let names = Subtitles.names(for: [sub(2, "eng", sdh: true), sub(7, "spa"), sub(8, "spa"), sub(9, nil)])
        XCTAssertEqual(names, [2: "English (SDH)", 7: "Spanish", 8: "Spanish 2", 9: "Unknown language"])

        let json = #"{"MediaSources":[{"Id":"ms1","MediaStreams":[{"Index":3,"Type":"Subtitle","Language":"eng","Codec":"subrip","IsDefault":true,"IsTextSubtitleStream":true}]}]}"#
        let info = try JSONCoding.decoder().decode(PlaybackInfoResponse.self, from: Data(json.utf8))
        let stream = try XCTUnwrap(info.mediaSources?.first?.mediaStreams?.first)
        XCTAssertTrue(stream.isSubtitle && stream.isText)
        XCTAssertEqual(stream.languageCode, "eng")
        XCTAssertEqual(client.subtitleURL(itemId: "i1", mediaSourceId: "ms1", index: 3).path,
                       "/jellyfin/Videos/i1/ms1/Subtitles/3/0/Stream.vtt")
    }

    func testDeviceProfileEncodesPascalCase() throws {
        let data = try JSONEncoder().encode(DeviceProfile.avPlayer())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let direct = try XCTUnwrap(obj["DirectPlayProfiles"] as? [[String: Any]])
        XCTAssertEqual(direct.first?["Container"] as? String, "mp4,m4v,mov")
        let hls = try XCTUnwrap((obj["TranscodingProfiles"] as? [[String: Any]])?.first)
        XCTAssertEqual(hls["VideoCodec"] as? String, "hevc,h264")
        XCTAssertEqual(hls["BreakOnNonKeyFrames"] as? Bool, true)
    }

    func testLandscapeArtFallsBackToParentBackdrop() throws {
        let json = #"{"Id":"m1","Type":"Movie","ParentBackdropItemId":"p1","ParentBackdropImageTags":["bt"]}"#
        let movie = try JSONCoding.decoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(client.landscapeURL(movie, width: 400)?.absoluteString,
                       "http://jf.test:8099/jellyfin/Items/p1/Images/Backdrop/0?maxWidth=400&quality=90&tag=bt")
    }

    func testResumeIgnoresAlmostFinished() throws {
        let json = #"{"Id":"m1","RunTimeTicks":1000,"UserData":{"PlaybackPositionTicks":990}}"#
        let movie = try JSONCoding.decoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(Format.resumeSeconds(movie), 0)
    }

    func testServerURLFromTypedText() {
        XCTAssertEqual(JellyfinClient.serverURL(from: " 192.168.1.10:8096/ ")?.absoluteString, "http://192.168.1.10:8096")
        XCTAssertEqual(JellyfinClient.serverURL(from: "https://jf.example.com/jellyfin//")?.absoluteString, "https://jf.example.com/jellyfin")
        XCTAssertEqual(JellyfinClient.serverURL(from: "HTTP://Media.local:8096")?.host, "Media.local")
        XCTAssertNil(JellyfinClient.serverURL(from: ""))
        XCTAssertNil(JellyfinClient.serverURL(from: "ftp://jf.example.com"))
        XCTAssertNil(JellyfinClient.serverURL(from: "http://"))
    }

    /// Live check against a real server: MARQUEE_TEST_SERVER=http://192.168.1.10:8096 swift test
    func testLivePublicEndpoints() async throws {
        guard let base = ProcessInfo.processInfo.environment["MARQUEE_TEST_SERVER"], let url = URL(string: base) else {
            throw XCTSkip("set MARQUEE_TEST_SERVER to run")
        }
        let live = JellyfinClient(server: url, deviceId: "marquee-ios-test", deviceName: "test")
        let info = try await live.publicInfo()
        XCTAssertNotNil(info.serverName)
        _ = try await live.publicUsers()
    }
}
