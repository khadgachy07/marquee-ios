#if os(iOS)
import MarqueeCore
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var results: [Item] = []
    @State private var searched = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                PosterGrid(items: results)
            }
            .overlay {
                if results.isEmpty, !searched.isEmpty {
                    ContentUnavailableView.search(text: searched)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Movies, shows, collections")
            .task(id: query) {
                let term = query.trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty else { results = []; searched = ""; return }
                try? await Task.sleep(for: .milliseconds(300))   // wait for typing to pause
                guard !Task.isCancelled else { return }
                if let found = try? await model.client.search(term), !Task.isCancelled {
                    results = found
                    searched = term
                }
            }
            .navigationDestination(for: Item.self) { DetailView(item: $0) }
        }
    }
}

struct MyListView: View {
    @Environment(AppModel.self) private var model
    @State private var items: [Item] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                PosterGrid(items: items)
            }
            .overlay {
                if loaded, items.isEmpty {
                    ContentUnavailableView("Your list is empty", systemImage: "plus.rectangle.on.rectangle",
                                           description: Text("Tap + on a movie or show to save it here."))
                }
            }
            .navigationTitle("My List")
            .refreshable { await load() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .marqueeLibraryChanged)) { _ in
                Task { await load() }
            }
            .navigationDestination(for: Item.self) { DetailView(item: $0) }
        }
    }

    private func load() async {
        items = (try? await model.client.favorites()) ?? items
        loaded = true
    }
}
#endif
