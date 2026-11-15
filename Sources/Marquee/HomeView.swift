#if os(iOS)
import MarqueeCore
import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var hero: Item?
    @State private var shelves: [Shelf] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if let hero {
                        HeroView(item: hero)
                    }
                    ForEach(shelves) { ShelfView(shelf: $0) }
                    if let error {
                        VStack(spacing: 12) {
                            Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 120)
                    }
                }
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
            .refreshable { await load() }
            .task { if !loaded { await load() } }
            .onReceive(NotificationCenter.default.publisher(for: .marqueeLibraryChanged)) { _ in
                Task { await load() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Wordmark() }
                ToolbarItem(placement: .topBarTrailing) { ProfileMenu() }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationDestination(for: Item.self) { DetailView(item: $0) }
        }
    }

    private func load() async {
        let client = model.client
        async let views = client.views()
        async let resume = client.resume()
        async let nextUp = client.nextUp()
        async let favorites = client.favorites()
        async let heroPick = client.items(["includeItemTypes": "Movie,Series", "imageTypes": "Backdrop",
                                           "sortBy": "Random", "isPlayed": "false", "limit": "1"])
        do {
            // The library list doubles as the "is the server reachable" check.
            let libraries = try await views.filter { $0.collectionType == "movies" || $0.collectionType == "tvshows" }
            var rows: [Shelf] = []
            let resumeItems = (try? await resume) ?? []
            if !resumeItems.isEmpty { rows.append(Shelf(id: "resume", title: "Continue Watching", items: resumeItems)) }
            let nextItems = (try? await nextUp) ?? []
            if !nextItems.isEmpty { rows.append(Shelf(id: "next", title: "Next Up", items: nextItems)) }
            let favoriteItems = (try? await favorites) ?? []
            if !favoriteItems.isEmpty { rows.append(Shelf(id: "list", title: "My List", items: favoriteItems, style: .poster)) }
            for library in libraries {
                let items = (try? await client.latest(parentId: library.id)) ?? []
                if !items.isEmpty {
                    rows.append(Shelf(id: "new-\(library.id)", title: "New in \(library.name ?? "Library")", items: items, style: .poster))
                }
            }
            hero = (try? await heroPick)?.items.first ?? hero
            shelves = rows
            error = rows.isEmpty && hero == nil ? "Nothing here yet. Your Jellyfin libraries look empty." : nil
        } catch {
            self.error = model.message(for: error)
        }
        loaded = true
    }
}

/// Full-width billboard: backdrop, logo or title, Play and More Info.
struct HeroView: View {
    @Environment(AppModel.self) private var model
    let item: Item

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: model.client.backdropURL(item))
                .frame(height: 480)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.4), .black], startPoint: .center, endPoint: .bottom)
            VStack(spacing: 14) {
                if let logo = model.client.logoURL(item) {
                    AsyncImage(url: logo) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(item.name ?? "").font(.largeTitle.bold())
                    }
                    .frame(maxWidth: 260, maxHeight: 100)
                } else {
                    Text(item.name ?? "").font(.largeTitle.bold()).multilineTextAlignment(.center)
                }
                Text(Format.meta(item)).font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    PlayButton(item: item)
                    NavigationLink(value: item) {
                        Label("More Info", systemImage: "info.circle")
                            .font(.headline)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// White Play / Resume button that opens the native player.
struct PlayButton: View {
    @Environment(AppModel.self) private var model
    let item: Item
    var label: String?

    var body: some View {
        Button {
            Player.play(item, client: model.client)
        } label: {
            Label(label ?? (Format.resumeSeconds(item) > 0 ? "Resume" : "Play"), systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(.white, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
#endif
