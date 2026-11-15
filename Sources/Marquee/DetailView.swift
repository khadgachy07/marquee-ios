#if os(iOS)
import MarqueeCore
import SwiftUI

/// Title page: artwork, Play/Resume, My List, overview; seasons and episodes for shows.
struct DetailView: View {
    @Environment(AppModel.self) private var model
    let item: Item

    @State private var full: Item?
    @State private var seasons: [Item] = []
    @State private var seasonId: String?
    @State private var episodes: [Item] = []
    @State private var playTarget: Item?
    @State private var similar: [Item] = []
    @State private var isFavorite = false
    @State private var error: String?

    /// Episodes open their show's page.
    private var titleId: String { item.isEpisode ? (item.seriesId ?? item.id) : item.id }
    private var shown: Item { full ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    Text(Format.meta(shown)).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        if let playTarget {
                            PlayButton(item: playTarget, label: playLabel(playTarget))
                        } else {
                            ProgressView().frame(height: 44)
                        }
                        Button { Task { await toggleFavorite() } } label: {
                            Image(systemName: isFavorite ? "checkmark" : "plus")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isFavorite ? "Remove from My List" : "Add to My List")
                        Menu {
                            WatchActions(item: shown, resumeItem: playTarget)
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.headline)
                                .frame(width: 44, height: 44)
                                .background(.white.opacity(0.15), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("More")
                        if shown.type == "Movie" {
                            DownloadButton(item: shown)
                        }
                    }
                    if let next = playTarget, next.isEpisode, let label = Format.episodeLabel(next) {
                        Text("\(label) “\(next.name ?? "")”").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let overview = shown.overview, !overview.isEmpty {
                        Text(overview).font(.body)
                    }
                    if let genres = shown.genres, !genres.isEmpty {
                        Text(genres.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(.horizontal)

                if shown.isSeries { episodesSection }

                if !similar.isEmpty {
                    ShelfView(shelf: Shelf(id: "similar", title: "More Like This", items: similar, style: .poster))
                }
            }
            .padding(.bottom, 24)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task { await load() }
        .onChange(of: seasonId) { _, id in
            Task { await loadEpisodes(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .marqueeLibraryChanged)) { _ in
            Task { await load() }
        }
    }

    private var header: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: model.client.backdropURL(shown))
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black], startPoint: .center, endPoint: .bottom)
            Group {
                if let logo = model.client.logoURL(shown) {
                    AsyncImage(url: logo) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Text(shown.name ?? "").font(.title.bold())
                    }
                    .frame(maxWidth: 240, maxHeight: 90, alignment: .leading)
                } else {
                    Text(shown.name ?? "").font(.title.bold())
                }
            }
            .padding()
        }
    }

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes").font(.headline)
                Spacer()
                if seasons.count > 1 {
                    Picker("Season", selection: $seasonId) {
                        ForEach(seasons) { season in
                            Text(season.name ?? "Season").tag(Optional(season.id))
                        }
                    }
                    .pickerStyle(.menu)
                } else if let only = seasons.first {
                    Text(only.name ?? "").foregroundStyle(.secondary)
                }
            }
            ForEach(episodes) { episode in
                // Side by side, not the download button laid over the row: nested in the row's own button,
                // a tap on it could start playback instead.
                HStack(spacing: 0) {
                    Button { Player.play(episode, client: model.client) } label: {
                        EpisodeRow(episode: episode)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { WatchActions(item: episode) }
                    DownloadButton(item: episode, size: 44, circled: false)
                        .padding(.trailing, 4)
                }
                .background(episode.id == playTarget?.id ? Color.white.opacity(0.08) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal)
    }

    private func playLabel(_ target: Item) -> String {
        Format.resumeSeconds(target) > 0 ? "Resume" : "Play"
    }

    private func load() async {
        let client = model.client
        do {
            let loaded = try await client.item(titleId)
            full = loaded
            isFavorite = loaded.userData?.isFavorite ?? false
            if loaded.isSeries {
                let list = try await client.seasons(seriesId: loaded.id)
                seasons = list
                let next = try? await client.playableItem(for: loaded)
                playTarget = next
                if seasonId == nil {
                    seasonId = next?.seasonId ?? list.first(where: { ($0.indexNumber ?? 0) > 0 })?.id ?? list.first?.id
                } else {
                    await loadEpisodes(seasonId)
                }
            } else {
                playTarget = loaded
            }
            error = nil
        } catch {
            self.error = model.message(for: error)
        }
        similar = (try? await client.similar(titleId)) ?? similar
    }

    private func loadEpisodes(_ id: String?) async {
        guard let id else { return }
        let list = (try? await model.client.episodes(seriesId: titleId, seasonId: id)) ?? []
        if seasonId == id { episodes = list }   // ignore answers for a season no longer picked
    }

    private func toggleFavorite() async {
        let next = !isFavorite
        isFavorite = next
        do {
            try await model.client.setFavorite(shown.id, next)
        } catch {
            isFavorite = !next
            self.error = model.message(for: error)
        }
    }
}

struct EpisodeRow: View {
    @Environment(AppModel.self) private var model
    let episode: Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottom) {
                RemoteImage(url: model.client.landscapeURL(episode, width: 400))
                    .frame(width: 140, height: 79)
                    .clipped()
                Image(systemName: "play.circle")
                    .font(.title)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                let progress = Format.progress(episode)
                if progress > 0, progress < 1 { ProgressLine(value: progress) }
            }
            .frame(width: 140, height: 79)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.name ?? "")")
                    .font(.subheadline.bold())
                    .lineLimit(2)
                if let rt = Format.runtime(episode.runTimeTicks) {
                    Text(rt).font(.caption).foregroundStyle(.secondary)
                }
                if let overview = episode.overview {
                    Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .opacity(episode.userData?.played == true ? 0.7 : 1)
        .contentShape(Rectangle())
    }
}
#endif
