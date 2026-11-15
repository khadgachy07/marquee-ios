# Marquee for iOS

A native iPhone app for your Jellyfin server, in the style of the Marquee web app.

- **Sign in**: "Who's watching?" profiles from your server, password if the profile has one.
  The access token is kept in the iOS Keychain.
- **Home**: a billboard, Continue Watching, Next Up, My List, and New in each movie/TV library.
- **Title pages**: Play/Resume, add to My List, overview, seasons and episodes, More Like This.
- **Search** and **My List** tabs.
- **Player**: Apple's own full-screen player (AVPlayer): resumes where you left off, reports progress
  to Jellyfin, plays the next episode automatically, Picture in Picture, AirPlay, lock-screen controls,
  and Apple's subtitle menu for subtitles Jellyfin includes in the stream.

Default server: `http://your-server:8099/jellyfin` (placeholder: replace `your-server` with your Jellyfin/Marquee host).
You can type another address on the sign-in screen.

## Layout

- `Sources/MarqueeCore`: Jellyfin API client, models, device profile. Plain Foundation; tested with `swift test`
  on Linux or macOS (`MARQUEE_TEST_SERVER=http://your-server:8099/jellyfin swift test` also checks the live server).
- `Sources/Marquee`: the SwiftUI app and player (iOS only).
- `xtool.yml` (bundle ID, icon) and `Info.plist` (background audio, HTTP allowed).

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
