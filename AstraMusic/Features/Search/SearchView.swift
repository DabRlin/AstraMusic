import SwiftUI

/// Search root: paged `/search` via `AuthStore.client`, split into four result
/// kinds (`SearchType`). Login-gated — signed out it renders `SignInWall`, and
/// every fetch re-checks `auth.isLoggedIn` so a mid-session sign-out cannot leave
/// stale rows behind.
struct SearchView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PlayerStore.self) private var player
    var onOpenAlbum: (Album) -> Void
    var onOpenArtist: (Artist) -> Void
    var onOpenPlaylist: (Playlist) -> Void

    @State private var query = ""
    @State private var type: SearchType = .song
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var message: String?
    @State private var page = 1
    @State private var total = 0
    @FocusState private var fieldFocused: Bool

    private let pageSize = 30

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in to search", systemImage: "magnifyingglass")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    searchField

                    Picker("Search type", selection: $type) {
                        ForEach(SearchType.allCases) { item in
                            Label(item.title, systemImage: item.systemImage).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .onChange(of: type) { _, _ in
                        // Switching kind restarts the query from page 1; it is not
                        // a "more results" load.
                        Task { await search() }
                    }

                    if let message {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                    }

                    // Distinguishes "nothing searched yet" from "searched, no
                    // results" (which is a `message`). The hint names the sidecar
                    // because search fails visibly when the local API is down.
                    if results.isEmpty, message == nil, !isSearching {
                        ContentUnavailableView(
                            "Search Kugou",
                            systemImage: "magnifyingglass",
                            description: Text(auth.apiReachable
                                ? "Type a title or artist, then press Return."
                                : "Start the local API sidecar first.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        resultList
                    }
                }
            }
        }
        .navigationTitle("Search")
        // Only focus the field when there is something to type into; never focus
        // it behind the sign-in wall.
        .onAppear { fieldFocused = auth.isLoggedIn }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search songs, artists, albums, playlists", text: $query)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onSubmit { Task { await search() } }
            if isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(24)
    }

    private var resultList: some View {
        List {
            ForEach(results) { item in
                resultView(item)
            }
            if hasMore {
                HStack {
                    Spacer()
                    if isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("More \(type.title.lowercased())…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .onAppear { Task { await loadMore() } }
            }
        }
        .listStyle(.plain)
        .hidesScrollIndicators()
    }

    @ViewBuilder
    private func resultView(_ item: SearchResult) -> some View {
        // Only songs play; albums/artists/playlists push a route through the
        // `onOpen*` callbacks so the carried object is the whole payload.
        switch item.type {
        case .song:
            if let song = item.song {
                Button {
                    // `SearchSong` lacks playback identity, so it is converted to
                    // a `Song`; `play` re-resolves the CDN URL from the hash.
                    player.play(song.asSong())
                } label: {
                    HStack(spacing: 12) {
                        CoverTile(song: song.asSong(), size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.title).foregroundStyle(.primary).lineLimit(1)
                            Text(song.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(song.asSong().durationLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        case .album:
            if let album = item.album {
                Button { onOpenAlbum(album) } label: {
                    resultRow(symbol: album.artworkSymbol, template: album.artworkTemplate, title: album.title, subtitle: album.artistName)
                }
                .buttonStyle(.plain)
            }
        case .author:
            if let artist = item.artist {
                Button { onOpenArtist(artist) } label: {
                    resultRow(symbol: artist.artworkSymbol, template: artist.artworkTemplate, title: artist.name, subtitle: item.subtitle)
                }
                .buttonStyle(.plain)
            }
        case .special:
            if let playlist = item.playlist {
                Button { onOpenPlaylist(playlist) } label: {
                    resultRow(symbol: playlist.artworkSymbol, template: playlist.artworkTemplate, title: playlist.name, subtitle: item.subtitle)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func resultRow(symbol: String, template: String?, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            CoverTile(symbol: symbol, template: template, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Mirrors `SearchPage.hasMore`; keep the two in sync. It is reimplemented
    /// here because this view holds only `page` and `total`, not the page object.
    private var hasMore: Bool {
        total > 0 ? page * pageSize < total : results.count >= pageSize
    }

    private func search() async {
        guard auth.isLoggedIn else { return }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            // Blank query clears the list without hitting the API.
            results = []
            message = nil
            page = 1
            total = 0
            return
        }
        isSearching = true
        message = nil
        page = 1
        do {
            let batch = try await auth.client.search(keywords: needle, type: type, page: 1, pageSize: pageSize)
            results = batch.results
            total = batch.total
            if results.isEmpty { message = "No \(type.title.lowercased()) for “\(needle)”." }
        } catch {
            results = []
            total = 0
            message = error.localizedDescription
        }
        isSearching = false
    }

    private func loadMore() async {
        // Guard the whole trigger: the footer's `onAppear` can fire repeatedly
        // while scrolling, and a search/type change must not mix in a stale page.
        guard auth.isLoggedIn, hasMore, !isLoadingMore, !isSearching else { return }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return }
        isLoadingMore = true
        let next = page + 1
        do {
            let batch = try await auth.client.search(keywords: needle, type: type, page: next, pageSize: pageSize)
            let existing = Set(results.map(\.id))
            // De-dupe by id: page boundaries can overlap and repeat rows.
            results.append(contentsOf: batch.results.filter { !existing.contains($0.id) })
            page = next
            total = batch.total
        } catch {
            message = error.localizedDescription
        }
        isLoadingMore = false
    }
}
