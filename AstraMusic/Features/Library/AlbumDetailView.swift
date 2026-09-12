import SwiftUI

/// Album route detail.
///
/// Albums are immutable here, so the route-carried snapshot is used directly.
/// No `LibraryStore` is injected: the screen is read-only and plays through
/// `PlayerStore`.
struct AlbumDetailView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(AuthStore.self) private var auth
    /// Carried by the route. Albums are never mutated from this screen, so the
    /// snapshot stays valid.
    let album: Album
    var onPlay: (Song) -> Void

    /// Fetched per album; `message` carries either the empty-list hint or the
    /// fetch error.
    @State private var songs: [Song] = []
    @State private var message: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in to see this album", systemImage: "square.stack.fill")
                    .navigationTitle("Album")
            } else {
                List {
                    Section {
                        DetailHeader(
                            title: album.title,
                            subtitle: album.artistName,
                            canPlay: !songs.isEmpty,
                            onPlay: { player.play(songs: songs) },
                            cover: { CoverTile(album: album, size: 96) }
                        )
                        .listRowBackground(Color.clear)
                    }
                    Section("Tracks") {
                        TrackListView(
                            songs: songs,
                            isLoading: isLoading,
                            message: message,
                            row: { song in
                                SongRow(song: song) {
                                    player.play(songs: songs, startingAt: song)
                                }
                            }
                        )
                    }
                }
                .hidesScrollIndicators()
                .navigationTitle(album.title)
                // Keyed by id so switching albums in the stack refetches.
                .task(id: album.id) {
                    isLoading = true
                    message = nil
                    do {
                        songs = try await auth.client.songs(in: album)
                        if songs.isEmpty { message = "No tracks on this album." }
                    } catch {
                        songs = []
                        message = error.localizedDescription
                    }
                    isLoading = false
                }
            }
        }
    }
}
