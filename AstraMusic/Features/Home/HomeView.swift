import SwiftUI

/// "For you" root: the signed-in discovery feed.
///
/// Fetches through `AuthStore.client` (the same client the player uses) and is
/// gated on `auth.isLoggedIn`; signed out it renders `SignInWall` instead, so
/// there is a single place where discovery content is hidden.
struct HomeView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    var onPlay: (Song) -> Void
    var onSearch: () -> Void = {}
    var onOpenPlaylist: (Playlist) -> Void = { _ in }

    @State private var releases: [Song] = []
    @State private var playlists: [Playlist] = []
    @State private var isLoading = false
    @State private var message: String?

    var body: some View {
        Group {
            if auth.isLoggedIn {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 28) {
                        searchField

                        section("Releases for You") {
                            if isLoading, releases.isEmpty {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(.vertical, 24)
                            } else if let message, releases.isEmpty {
                                Text(message)
                                    .foregroundStyle(.secondary)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(releases) { song in
                                            SongCard(song: song) { onPlay(song) }
                                        }
                                    }
                                }
                            }
                        }

                        if !playlists.isEmpty {
                            section("Recommended Playlists") {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                        ForEach(playlists) { playlist in
                                            PlaylistCard(playlist: playlist) {
                                                onOpenPlaylist(playlist)
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        section("Recently Played") {
                            // Local, login-gated history from `LibraryStore`;
                            // `/user/listen` is deliberately not used.
                            if library.recentSongs.isEmpty {
                                Text("Play a song and it will show up here.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(library.recentSongs) { song in
                                    SongRow(song: song) { onPlay(song) }
                                }
                            }
                        }
                    }
                    .padding(24)
                }
                .hidesScrollIndicators()
            } else {
                SignInWall(title: "Sign in to browse Kugou", systemImage: "sparkles")
            }
        }
        .navigationTitle("For you")
        // Reload when the sign-in state flips: signing in enables the feed, and
        // signing out must drop the rows since they belonged to the previous
        // account.
        .task(id: auth.isLoggedIn) {
            if auth.isLoggedIn {
                await load()
            } else {
                releases = []
                playlists = []
                message = nil
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.weight(.semibold))
            content()
        }
    }

    private var searchField: some View {
        // A button, not a live field: tapping switches the sidebar root to Search
        // (via `onSearch`), so the query and its paging live in exactly one view.
        Button(action: onSearch) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Search songs, albums, artists")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Open Search")
    }

    @MainActor
    private func load() async {
        isLoading = true
        message = nil
        do {
            async let daily = auth.client.dailyRecommend()
            async let featured = auth.client.recommendedPlaylists()
            let songs = try await daily
            // Curated playlists are best-effort: losing them should not blank the
            // feed. A daily-recommend failure is fatal and handled in `catch`.
            let lists = (try? await featured) ?? []
            // Bound the horizontal rows; the API returns far more than fits.
            releases = Array(songs.prefix(12))
            playlists = Array(lists.prefix(12))
            if releases.isEmpty {
                message = "No daily recommendations right now."
            }
        } catch {
            // Shown as the section message (sidecar down, expired session, risk
            // verification) — never swallowed into an empty grid.
            releases = []
            playlists = []
            message = error.localizedDescription
        }
        isLoading = false
    }
}

/// Artwork + name + one-line intro for a recommended playlist. The whole card is
/// the tap target and pushes a `.playlist` route via `onOpen`.
struct PlaylistCard: View {
    let playlist: Playlist
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                CoverTile(
                    symbol: playlist.artworkSymbol,
                    template: playlist.artworkTemplate
                )
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(playlist.intro ?? "Playlist")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Theme.coverCard, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}
