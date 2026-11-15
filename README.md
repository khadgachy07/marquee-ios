# Marquee for iOS

A native iPhone app for [Jellyfin](https://jellyfin.org), the free self-hosted media server.
Bring your own server: Marquee doesn't come with one and doesn't send anything anywhere else.

- **Sign in**: enter your server's address, then pick a "Who's watching?" profile (password if the
  profile has one). The access token is kept in the iOS Keychain.
- **Home**: a billboard, Continue Watching, Next Up, My List, and New in each movie/TV library.
- **Title pages**: Play/Resume, add to My List, overview, seasons and episodes, More Like This.
- **Search**, **My List** and **Downloads** tabs.
- **Player**: Apple's own full-screen player (AVPlayer): resumes where you left off, reports progress
  to Jellyfin, plays the next episode automatically, Picture in Picture, AirPlay, lock-screen controls,
  and subtitles.

## Connecting to your server

On first launch, type the address you use to open Jellyfin in a browser:

| Your setup | Address to enter |
| --- | --- |
| Same Wi-Fi as the server | `http://192.168.1.10:8096` (your server's local IP; 8096 is Jellyfin's default port) |
| Reverse proxy / domain | `https://jellyfin.example.com`, plus any sub-path, e.g. `https://example.com/jellyfin` |
| VPN (Tailscale, WireGuard, ...) | the server's VPN address, e.g. `http://100.x.y.z:8096` |

`http://` is added if you leave it out. The phone has to be able to reach the server: on the same network,
with the VPN on, or over the internet. Plain HTTP is allowed because most home servers don't have HTTPS.
The app remembers the address; sign out to change it. Requires Jellyfin 10.9 or newer.

## Layout

- `Sources/MarqueeCore`: Jellyfin API client, models, device profile. Plain Foundation; tested with `swift test`
  on Linux or macOS (`MARQUEE_TEST_SERVER=http://192.168.1.10:8096 swift test` also checks a live server).
- `Sources/Marquee`: the SwiftUI app and player (iOS only).
- `xtool.yml` (bundle ID, icon) and `Info.plist` (background audio, HTTP allowed, local network access).

## Build on a Mac (free Apple ID is enough)

1. Install **Xcode** from the App Store and open it once.
2. Sign in: Xcode → Settings → Accounts → **+** → Apple ID. This creates your free "Personal Team".
3. Install xtool and generate the Xcode project:

   ```bash
   brew install xtool-org/tap/xtool
   cd marquee-ios
   xtool dev generate-xcode-project
   ```

4. Open the generated `xtool/Marquee.xcworkspace` (not the `marquee-ios` folder or `Package.swift`:
   that only builds the library and has nothing to run). Pick the **Marquee-App** scheme, select the
   `Marquee-App` target → **Signing & Capabilities** → Team: your Personal Team. If Xcode says the
   bundle ID is taken, change its last part.
5. Connect the iPhone by USB, tap **Trust**, turn on **Settings → Privacy & Security → Developer Mode**,
   pick the iPhone as the run destination and press **Run** (⌘R).
6. First launch may say "Untrusted Developer": allow it in **Settings → General → VPN & Device Management**.

With a free Apple ID the app stops opening after **7 days**; plug in the phone and press Run again to renew.

## Not in this version yet

- Choosing audio tracks or other subtitles: the player uses the file's default audio and default subtitles
  (switch subtitles off in Apple's menu). Picking others would need the stream reloaded.
- Skip Intro, trickplay thumbnails, cast pages, genre rows.
