import SwiftUI

/// The middle column's routing: the selected root inside a `NavigationStack`
/// whose `path` is the shared `NavigationModel`.
///
/// Owns the root↔route mapping so `ContentView` stays a shell; each root only
/// surfaces `onPlay` / `onOpen*` callbacks. Playback is resolved here through
/// `PlayerStore`, so the roots never hold it themselves.
struct DetailRouter: View {
    @Environment(PlayerStore.self) private var player
    @Bindable var nav: NavigationModel

    var body: some View {
        NavigationStack(path: $nav.path) {
            root
                .navigationDestination(for: Route.self) { route in
                    destination(for: route)
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        // Each root renders inside the same `NavigationStack(path:)`, so pushes
        // from any root land on `path` above.
        switch nav.section {
        case .forYou:
            HomeView(onPlay: play, onSearch: { nav.section = .search }, onOpenPlaylist: nav.openPlaylist)
        case .search:
            SearchView(
                onOpenAlbum: nav.openAlbum,
                onOpenArtist: nav.openArtist,
                onOpenPlaylist: nav.openPlaylist
            )
        case .library:
            LibraryView(
                onPlay: play,
                onOpenAlbum: nav.openAlbum,
                onOpenArtist: nav.openArtist,
                onOpenPlaylist: nav.openPlaylist
            )
        case .likedSongs:
            LikedSongsView(onPlay: play)
        case .albums:
            AlbumsView(onPlay: play, onOpenAlbum: nav.openAlbum)
        case .artists:
            ArtistsView(onPlay: play, onOpenArtist: nav.openArtist)
        case .recent:
            RecentView(onPlay: play)
        case .createdPlaylists:
            PlaylistFolderView(kind: .created, onOpenPlaylist: nav.openPlaylist, onPlay: play)
        case .collectedPlaylists:
            PlaylistFolderView(kind: .collected, onOpenPlaylist: nav.openPlaylist, onPlay: play)
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        // The route carries the full object so the detail view can render
        // immediately; `PlaylistDetailView` still re-resolves by id for fresh
        // rename / collect state.
        switch route {
        case .playlist(let playlist):
            PlaylistDetailView(fallback: playlist, onPlay: play)
        case .album(let album):
            AlbumDetailView(album: album, onPlay: play)
        case .artist(let artist):
            ArtistDetailView(artist: artist, onPlay: play, onOpenAlbum: nav.openAlbum)
        }
    }

    private func play(_ song: Song) {
        player.play(song)
    }
}
