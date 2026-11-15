#if os(iOS)
import AVFoundation
import MarqueeCore

/// Hands AVPlayer Jellyfin's HLS master playlist marked "no closed captions" (see HLS.withoutClosedCaptions), so the
/// player doesn't show its own, empty, subtitles button next to the app's. The master playlist is fetched here through
/// a made-up URL scheme; everything it points to (the variant playlist, the segments) AVPlayer loads directly.
final class MasterPlaylistLoader: NSObject, AVAssetResourceLoaderDelegate {
    private static let schemes = ["http": "marquee-http", "https": "marquee-https"]
    private let queue = DispatchQueue(label: "app.marquee.master-playlist")

    /// The asset to play: HLS master playlists come through this loader, anything else (files, MP4) as it is.
    func asset(for url: URL) -> AVURLAsset {
        guard url.path.lowercased().hasSuffix("/master.m3u8"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme.flatMap({ Self.schemes[$0] }) else { return AVURLAsset(url: url) }
        parts.scheme = scheme
        guard let custom = parts.url else { return AVURLAsset(url: url) }
        let asset = AVURLAsset(url: custom)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let original = Self.schemes.first(where: { $0.value == parts.scheme })?.key else { return false }
        parts.scheme = original
        guard let real = parts.url else { return false }
        URLSession.shared.dataTask(with: real) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(status) else {
                loadingRequest.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            let text = HLS.withoutClosedCaptions(String(decoding: data, as: UTF8.self), base: real)
            loadingRequest.dataRequest?.respond(with: Data(text.utf8))
            loadingRequest.finishLoading()
        }.resume()
        return true
    }
}
#endif
