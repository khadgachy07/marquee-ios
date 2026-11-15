#if os(iOS)
import AVFoundation
import MarqueeCore
import SwiftUI

@main
struct MarqueeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // Sound plays with the silent switch on and keeps going in the background / Picture in Picture.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Artwork cache for AsyncImage (it uses URLSession.shared).
        URLCache.shared = URLCache(memoryCapacity: 64 << 20, diskCapacity: 512 << 20)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(.red)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSignedIn {
            MainTabs()
        } else {
            LoginView()
        }
    }
}

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "house.fill") }
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
            MyListView()
                .tabItem { Label("My List", systemImage: "plus.rectangle.on.rectangle") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
        }
        // Downloads stop while the app is in the background; carry on when it's back.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { Downloads.shared.resumeInterrupted(client: model.client) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.allowed
    }
}

/// Like Netflix: browsing stays portrait, the player turns the screen to landscape.
@MainActor
enum Orientation {
    static var allowed: UIInterfaceOrientationMask = .portrait

    static func lock(_ mask: UIInterfaceOrientationMask) {
        allowed = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}

extension Notification.Name {
    /// Posted when the player closes or watch state changes, so "Continue Watching" and My List refresh.
    static let marqueeLibraryChanged = Notification.Name("marqueeLibraryChanged")
}
#endif
