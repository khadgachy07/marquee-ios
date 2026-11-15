#if os(iOS)
import MarqueeCore
import SwiftUI

/// Artwork with a dark placeholder while loading or when missing.
struct RemoteImage: View {
    let url: URL?

    var body: some View {
        // Takes exactly the size it's offered: a filled image would otherwise report its overflow
        // as its own size and push siblings (billboard logo, buttons) off screen.
        Color.clear
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Color(white: 0.14)
                    }
                }
            }
            .clipped()
            // clipped() only hides the overflow; without this it still catches taps meant for the next card.
            .contentShape(Rectangle())
    }
}

struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.3))
                Rectangle().fill(.red).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 3)
    }
}

enum CardStyle {
    case landscape, poster

    var size: CGSize {
        switch self {
        case .landscape: CGSize(width: 220, height: 124)
        case .poster: CGSize(width: 120, height: 180)
        }
    }
}

struct CardView: View {
    @Environment(AppModel.self) private var model
    let item: Item
    var style: CardStyle = .landscape

    private var title: String {
        if item.isEpisode {
            return [item.seriesName, Format.episodeLabel(item)].compactMap { $0 }.joined(separator: " · ")
        }
        return item.name ?? ""
    }

    var body: some View {
        let size = style.size
        let art = style == .landscape ? model.client.landscapeURL(item) : model.client.posterURL(item)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: art)
                    .frame(width: size.width, height: size.height)
                    .clipped()
                let progress = Format.progress(item)
                if progress > 0, progress < 1 {
                    ProgressLine(value: progress)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: size.width, alignment: .leading)
        }
    }
}

/// "Mark as Watched" and "Remove from Continue Watching", for long-press menus and the title page's ••• menu.
struct WatchActions: View {
    @Environment(AppModel.self) private var model
    let item: Item
    /// The episode holding the resume point when `item` is a show; defaults to `item`.
    var resumeItem: Item?

    var body: some View {
        let played = item.userData?.played ?? false
        Button {
            change { try await $0.setPlayed(item.id, !played) }
        } label: {
            Label(played ? "Mark as Unwatched" : "Mark as Watched", systemImage: played ? "eye.slash" : "checkmark.circle")
        }
        let resumable = resumeItem ?? item
        if Format.resumeSeconds(resumable) > 0 {
            Button {
                change { try await $0.clearResume(resumable.id) }
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
            }
        }
    }

    private func change(_ action: @escaping (JellyfinClient) async throws -> Void) {
        let client = model.client
        Task {
            do {
                try await action(client)
            } catch {
                _ = model.message(for: error)   // signs out on an expired session
            }
            NotificationCenter.default.post(name: .marqueeLibraryChanged, object: nil)
        }
    }
}

struct Shelf: Identifiable {
    let id: String
    let title: String
    let items: [Item]
    var style: CardStyle = .landscape
}

/// A titled, horizontally scrolling row of cards.
struct ShelfView: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title)
                .font(.headline)
                .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(shelf.items) { item in
                        NavigationLink(value: item) {
                            CardView(item: item, style: shelf.style)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { WatchActions(item: item) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// Wrapping grid of posters (search results, My List).
struct PosterGrid: View {
    let items: [Item]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 16) {
            ForEach(items) { item in
                NavigationLink(value: item) {
                    CardView(item: item, style: .poster)
                }
                .buttonStyle(.plain)
                .contextMenu { WatchActions(item: item) }
            }
        }
        .padding()
    }
}

struct ProfileMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            if let name = model.user?.name {
                Text("Signed in as \(name)")
            }
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                model.signOut()
            }
        } label: {
            Group {
                if let user = model.user, let url = model.client.userImageURL(user, size: 80) {
                    RemoteImage(url: url)
                } else {
                    Image(systemName: "person.crop.circle.fill").resizable()
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// The red wordmark used in navigation bars.
struct Wordmark: View {
    var body: some View {
        Text("MARQUEE")
            .font(.system(size: 22, weight: .black))
            .foregroundStyle(.red)
            .fixedSize()
    }
}
#endif
