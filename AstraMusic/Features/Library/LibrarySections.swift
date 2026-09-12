import SwiftUI

/// Standalone Library screens: the Liked Songs entry point and the Albums,
/// Artists, and Recent roots reached from the sidebar.

/// Route entry for Liked Songs.
///
/// Synthesizes the `"liked"` id that `LibraryStore.playlist(id:)` recognizes.
/// `songIDs` is empty on purpose: the rows come from the account liked list plus
/// the local likes bucket, not from the stored id list.
struct LikedSongsView: View {
    var onPlay: (Song) -> Void

    var body: some View {
        PlaylistDetailView(
            fallback: Playlist(
                id: "liked",
                name: "Liked Songs",
                artworkSymbol: "heart.fill",
                songIDs: [],
                kind: .liked
            ),
            onPlay: onPlay
        )
    }
}

/// Standalone Albums root reached from the sidebar.
///
/// Albums are account-library only and not cloud-synced in this build, so there
/// is no collect action and no local cache: signed out, or before the first
/// refresh, the list is simply empty.
struct AlbumsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    var onPlay: (Song) -> Void
    var onOpenAlbum: (Album) -> Void

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in for albums", systemImage: "square.stack.fill")
            } else if library.allAlbums.isEmpty {
                ContentUnavailableView("No albums", systemImage: "square.stack.fill")
            } else {
                List(library.allAlbums) { album in
                    HStack(spacing: 12) {
                        CoverTile(album: album, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(album.title)
                            Text(album.artistName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenAlbum(album) }
                }
                .hidesScrollIndicators()
            }
        }
        .navigationTitle("Albums")
    }
}

/// Standalone Artists root reached from the sidebar.
///
/// The roster is the account's followed artists; follow state is derived from
/// the account library and never persisted locally.
struct ArtistsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    var onPlay: (Song) -> Void
    var onOpenArtist: (Artist) -> Void

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in for artists", systemImage: "person.2")
            } else if library.allArtists.isEmpty {
                ContentUnavailableView("No artists", systemImage: "person.2")
            } else {
                List(library.allArtists) { artist in
                    Button {
                        onOpenArtist(artist)
                    } label: {
                        HStack(spacing: 12) {
                            CoverTile(artist: artist, size: 48)
                            Text(artist.name)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .hidesScrollIndicators()
            }
        }
        .navigationTitle("Artists")
    }
}

/// Recent route: the local, per-userid play history written by
/// `PlayerStore.onSongStarted -> LibraryStore.recordPlay`.
///
/// Nothing is fetched from the server (`/user/listen` is not used), so this is
/// empty on a fresh install or while signed out.
struct RecentView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    var onPlay: (Song) -> Void

    @State private var songSelection: Set<String> = []
    @State private var songAnchor: Int?

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in to see recent plays", systemImage: "clock")
            } else if library.recentSongs.isEmpty {
                ContentUnavailableView("Nothing played yet", systemImage: "clock")
            } else {
                List(library.recentSongs) { song in
                    SongRow(song: song, selection: recentRowSelection(for: song)) { onPlay(song) }
                }
                .hidesScrollIndicators()
            }
        }
        .navigationTitle("Recent")
        .escClearsSelection(
            isActive: { !songSelection.isEmpty },
            clear: {
                songSelection = []
                songAnchor = nil
            }
        )
    }

    /// Reads the order straight from the store each call so a shift-range
    /// matches the list currently on screen.
    private func recentRowSelection(for song: Song) -> SongRowSelection {
        let songs = library.recentSongs
        return SongRowSelection(
            isSelected: songSelection.contains(song.id),
            isBatch: songSelection.count > 1 && songSelection.contains(song.id),
            selectedSongs: songs.filter { songSelection.contains($0.id) },
            onIntent: { intent in
                RowSelection.apply(
                    intent, id: song.id, order: songs.map(\.id),
                    selected: &songSelection, anchor: &songAnchor
                )
            }
        )
    }
}
