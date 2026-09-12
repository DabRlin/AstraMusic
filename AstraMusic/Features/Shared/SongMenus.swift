/// Home of the `songLibraryActions` View extension and the context menus it
/// attaches (`SongLibraryMenu` / `SongBatchMenu`).

import SwiftUI

extension View {
    /// Attaches the song's context menu. Pass `selection` to get the batch menu
    /// once more than one row is selected, and `inLikedCollection` to move the
    /// like toggle to the bottom where it reads as removal.
    func songLibraryActions(
        _ song: Song,
        removeFrom playlist: Playlist? = nil,
        selection: SongRowSelection? = nil,
        inLikedCollection: Bool = false
    ) -> some View {
        modifier(SongLibraryActionsModifier(
            song: song,
            playlist: playlist,
            selection: selection,
            inLikedCollection: inLikedCollection
        ))
    }
}

/// Attaches the row context menu, choosing the batch variant when the row is
/// part of a multi-selection.
private struct SongLibraryActionsModifier: ViewModifier {
    let song: Song
    var playlist: Playlist?
    var selection: SongRowSelection?
    var inLikedCollection: Bool = false
    @Environment(LibraryStore.self) private var library

    func body(content: Content) -> some View {
        // Menu content is its own view so Queue / List rows do not subscribe
        // to displayedPlaylists (account refresh used to UAF SongRow).
        content.contextMenu {
            if let selection, selection.isBatch {
                SongBatchMenu(
                    songs: selection.selectedSongs,
                    removeFrom: selection.removeFrom,
                    inLikedCollection: inLikedCollection
                )
            } else {
                SongLibraryMenu(
                    song: song,
                    playlist: playlist,
                    inLikedCollection: inLikedCollection
                )
            }
        }
    }
}

/// Context menu for a single song: like/unlike, add to a writable playlist, and
/// (when `playlist` allows) remove from it.
private struct SongLibraryMenu: View {
    let song: Song
    var playlist: Playlist?
    /// Liked Songs: the like toggle removes the row from the list, so it goes
    /// last, like a remove action.
    var inLikedCollection: Bool = false
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if !inLikedCollection {
            likeToggle
        }

        let targets = library.displayedPlaylists
        // Kept visible but disabled when there is nowhere to add, so the menu
        // keeps a predictable shape.
        if targets.isEmpty {
            Button("Add to Playlist") {}
                .disabled(true)
        } else {
            Menu("Add to Playlist") {
                ForEach(targets) { item in
                    Button(item.name) {
                        library.requestAdd(song, to: item)
                    }
                }
            }
        }

        // Removal is only offered for local / owned playlists, and never for
        // Liked Songs where unlike is the remove equivalent.
        if let playlist, playlist.id != "liked",
           playlist.kind == .local || playlist.kind == .owned {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                library.requestRemove(song, from: playlist)
            }
        }

        if inLikedCollection {
            Divider()
            likeToggle
        }
    }

    @ViewBuilder
    private var likeToggle: some View {
        Button {
            library.requestToggleLike(song)
        } label: {
            Label(
                library.isLiked(song) ? "Unlike" : "Like",
                systemImage: library.isLiked(song) ? "heart.slash" : "heart"
            )
        }
    }
}

/// Right-click menu for a multi-selection: every action applies to all
/// selected rows.
/// Context menu for a multi-selection: every action applies to all selected
/// songs at once.
private struct SongBatchMenu: View {
    let songs: [Song]
    var removeFrom: Playlist?
    /// Liked Songs: the like toggle removes the rows from the list, so it goes
    /// last, like a remove action.
    var inLikedCollection: Bool = false

    @Environment(LibraryStore.self) private var library

    var body: some View {
        if !inLikedCollection {
            likeToggle
        }

        let targets = library.displayedPlaylists
        // Kept visible but disabled when there is nowhere to add, so the menu
        // keeps a predictable shape.
        if targets.isEmpty {
            Button("Add to Playlist") {}
                .disabled(true)
        } else {
            Menu("Add to Playlist") {
                ForEach(targets) { item in
                    Button(item.name) {
                        library.requestAdd(songs, to: item)
                    }
                }
            }
        }

        // Removal is only offered for local / owned playlists, and never for
        // Liked Songs where unlike is the remove equivalent.
        if let removeFrom, removeFrom.id != "liked",
           removeFrom.kind == .local || removeFrom.kind == .owned {
            Divider()
            Button("Remove from Playlist", role: .destructive) {
                library.requestRemove(songs, from: removeFrom)
            }
        }

        if inLikedCollection {
            Divider()
            likeToggle
        }
    }

    @ViewBuilder
    private var likeToggle: some View {
        Button {
            library.requestToggleLike(songs)
        } label: {
            Label(
                library.isLiked(songs) ? "Unlike" : "Like",
                systemImage: library.isLiked(songs) ? "heart.slash" : "heart.fill"
            )
        }
    }
}
