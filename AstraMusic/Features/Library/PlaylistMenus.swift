import SwiftUI

/// Context menus for playlist tiles: the single-item actions and the
/// multi-selection batch variant, both shared by the library and folder grids.

/// Right-click actions for a single playlist tile.
///
/// Each branch is gated by `Playlist.kind`: only collected / owned lists can be
/// pinned, only collected lists can be uncollected, and only owned / local lists
/// can be deleted. The liked row and Home curation get no actions at all.
struct PlaylistContextActions: View {
    let playlist: Playlist
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if playlist.kind == .collected || playlist.kind == .owned {
                Button {
                    library.togglePinned(playlist)
                } label: {
                    Label(
                        library.isPinned(playlist) ? "Unpin from Sidebar" : "Pin to Sidebar",
                        systemImage: library.isPinned(playlist) ? "pin.slash" : "pin"
                    )
                }
            }
            if playlist.kind == .collected {
                Divider()
                Button {
                    library.requestToggleFavorite(playlist)
                } label: {
                    Label("Uncollect", systemImage: "star.slash")
                }
            }
            if playlist.kind == .owned || playlist.kind == .local {
                Divider()
                Button("Delete Playlist", role: .destructive) {
                    library.requestDeletePlaylist(playlist)
                }
            }
        }
    }
}

/// Right-click actions for a multi-selection of playlist tiles.
///
/// The menu only appears when the whole selection qualifies (`allSatisfy`), so a
/// mixed selection offers no uncollect / delete rather than a partial action.
/// Pinning reads `allPinned` to pick one direction, then toggles every member,
/// so the selection moves to a uniform state instead of inverting per item.
struct PlaylistBatchMenu: View {
    let playlists: [Playlist]
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if playlists.allSatisfy({ $0.kind == .collected || $0.kind == .owned }) {
                let allPinned = playlists.allSatisfy { library.isPinned($0) }
                Button {
                    for playlist in playlists { library.togglePinned(playlist) }
                } label: {
                    Label(
                        allPinned ? "Unpin from Sidebar" : "Pin to Sidebar",
                        systemImage: allPinned ? "pin.slash" : "pin"
                    )
                }
            }
            if playlists.allSatisfy({ $0.kind == .collected }) {
                Divider()
                Button {
                    for playlist in playlists { library.requestToggleFavorite(playlist) }
                } label: {
                    Label("Uncollect", systemImage: "star.slash")
                }
            }
            if playlists.allSatisfy({ $0.kind == .owned || $0.kind == .local }) {
                Divider()
                Button("Delete Playlists", role: .destructive) {
                    for playlist in playlists { library.requestDeletePlaylist(playlist) }
                }
            }
        }
    }
}
