import SwiftUI

/// Detail screen shared by Liked Songs, local / owned / collected playlists,
/// and featured (search / Home) playlists.
///
/// The route only carries a `Playlist` snapshot; library-backed lists are
/// re-resolved from `LibraryStore` by id so renames and collect state stay
/// fresh, with the snapshot as fallback for lists the library does not hold.
struct PlaylistDetailView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    /// Carried by the route. Playlists that live in the library are
    /// re-resolved by id so renames and refreshes are reflected; search and
    /// recommended playlists fall back to the carried snapshot.
    let fallback: Playlist
    var onPlay: (Song) -> Void

    // Rename / delete alerts, only reachable when `canMutateLocal` is true.
    @State private var renameText = ""
    @State private var showRename = false
    @State private var showDelete = false
    /// Tracks fetched from the account; local lists read `library.songs(ids:)`.
    @State private var remoteSongs: [Song] = []
    @State private var remoteMessage: String?
    @State private var isLoadingRemote = false
    @Environment(\.dismiss) private var dismiss
    /// Notes-style multi-select for the track list.
    @State private var songSelection: Set<String> = []
    @State private var songAnchor: Int?

    /// Resolves the route snapshot against the live library.
    ///
    /// `.featured` lists never live in the library, so the snapshot is all there
    /// is; `.liked` tracks the account row so name/artwork follow a refresh;
    /// everything else must be found by id. `nil` therefore means the playlist
    /// was deleted or uncollected while open, and the body shows a placeholder.
    private var playlist: Playlist? {
        switch fallback.kind {
        case .featured:
            return fallback
        case .liked:
            return library.accountLikedPlaylist ?? fallback
        case .local, .owned, .collected, .collectedAlbum:
            return library.playlist(id: fallback.id)
        }
    }

    private var isLikedCollection: Bool { playlist?.kind == .liked }
    /// Whether the track list comes from the network.
    ///
    /// Liked Songs waits for `hasAccountLibrary` so it does not fetch before the
    /// account is known; local playlists never fetch (they live on disk).
    private var fetchesRemote: Bool {
        guard let playlist else { return false }
        if isLikedCollection { return library.hasAccountLibrary }
        return playlist.kind != .local
    }
    /// Rename / delete apply to on-this-Mac lists only; the liked row is never
    /// deletable.
    private var canMutateLocal: Bool {
        guard let playlist else { return false }
        return playlist.kind == .local && !isLikedCollection
    }
    /// Tracks can be removed from local / owned playlists. Collected
    /// playlists are read-only mirrors of someone else's list.
    private var canRemoveSongs: Bool {
        guard let playlist else { return false }
        return playlist.kind == .local || playlist.kind == .owned
    }

    var body: some View {
        if !auth.isLoggedIn {
            SignInWall(
                title: isLikedCollection ? "Sign in for your liked songs" : "Sign in to see this playlist",
                systemImage: isLikedCollection ? "heart.fill" : "music.note.list"
            )
            .navigationTitle(isLikedCollection ? "Liked Songs" : "Playlist")
        } else if let playlist {
            let songs = displaySongs(for: playlist)
            List {
                Section {
                    DetailHeader(
                        title: playlist.name,
                        subtitle: "\(songs.count) songs",
                        canPlay: !songs.isEmpty,
                        onPlay: { player.play(songs: songs) },
                        cover: {
                            CoverTile(
                                symbol: playlist.artworkSymbol,
                                template: headerArtwork(for: playlist, songs: songs),
                                size: 96
                            )
                        },
                        actions: {
                            // Collect is offered for browsable / collected lists
                            // only. There is no album branch: album collect is
                            // not implemented in this build.
                            if playlist.kind == .featured || playlist.kind == .collected {
                                DetailToggleButton(
                                    title: library.isFavorite(playlist) ? "Collected" : "Collect",
                                    systemImage: library.isFavorite(playlist) ? "star.fill" : "star"
                                ) {
                                    library.requestToggleFavorite(playlist)
                                }
                            }
                            // Pins are id-based and must survive a refresh, so
                            // only collected / owned lists qualify here.
                            if playlist.kind == .collected || playlist.kind == .owned {
                                DetailToggleButton(
                                    title: library.isPinned(playlist) ? "Pinned" : "Pin to Sidebar",
                                    systemImage: library.isPinned(playlist) ? "pin.fill" : "pin"
                                ) {
                                    library.togglePinned(playlist)
                                }
                            }
                            if canMutateLocal {
                                Button("Rename") {
                                    renameText = playlist.name
                                    showRename = true
                                }
                                Button("Delete", role: .destructive) {
                                    showDelete = true
                                }
                            }
                        }
                    )
                    .listRowBackground(Color.clear)
                }

                Section("Tracks") {
                    TrackListView(
                        songs: songs,
                        isLoading: isLoadingRemote,
                        message: remoteMessage,
                        empty: {
                            Text(emptyTracksMessage)
                                .foregroundStyle(.secondary)
                        },
                        row: { song in
                            // `removeFrom` also supplies the playlist-row fileid
                            // the remove endpoint needs; nil for collected lists,
                            // which are read-only mirrors.
                            SongRow(
                                song: song,
                                removeFrom: canRemoveSongs ? playlist : nil,
                                selection: songRowSelection(for: song, in: songs),
                                inLikedCollection: isLikedCollection
                            ) {
                                player.play(songs: songs, startingAt: song)
                            }
                        }
                    )
                }
            }
            .hidesScrollIndicators()
            .navigationTitle(playlist.name)
            .escClearsSelection(
                isActive: { !songSelection.isEmpty },
                clear: {
                    songSelection = []
                    songAnchor = nil
                }
            )
            // Keyed by id, not the object: a rename must not trigger a refetch.
            .task(id: playlist.id) {
                await loadRemoteIfNeeded(playlist)
            }
            .alert("Rename Playlist", isPresented: $showRename) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    library.renamePlaylist(id: playlist.id, to: renameText)
                }
            }
            .alert("Delete “\(playlist.name)”?", isPresented: $showDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    // Pop first: once the list is gone the body would otherwise
                    // fall back to the placeholder for a frame.
                    library.deletePlaylist(id: playlist.id)
                    dismiss()
                }
            } message: {
                Text("This playlist will be removed from your library.")
            }
        } else {
            PlaceholderPage(
                title: "Playlist",
                systemImage: "music.note.list",
                detail: "This playlist is no longer in your library."
            )
        }
    }

    /// Shown when a fetched or local list has no tracks.
    private var emptyTracksMessage: String {
        "No songs yet."
    }

    /// Liked Songs uses the most recently liked track's cover, matching Kugou.
    private func headerArtwork(for playlist: Playlist, songs: [Song]) -> String? {
        if isLikedCollection {
            return songs.first?.artworkTemplate
                ?? library.accountLikedSongs.first?.artworkTemplate
                ?? playlist.artworkTemplate
        }
        return playlist.artworkTemplate ?? songs.first?.artworkTemplate
    }

    /// Fallback chain for the visible track list.
    ///
    /// Once loaded, remote results win, but only liked lists merge them with
    /// local likes. Local lists resolve from the remembered-song cache, so ids
    /// that were never remembered are silently dropped.
    private func displaySongs(for playlist: Playlist) -> [Song] {
        if isLikedCollection {
            if fetchesRemote, !remoteSongs.isEmpty {
                return mergeLiked(remote: remoteSongs)
            }
            return library.likedSongs
        }
        if fetchesRemote { return remoteSongs }
        return library.songs(ids: playlist.songIDs)
    }

    /// Remote liked songs first, then anything liked locally that the account
    /// read has not caught up with yet; de-duplicated by canonical id so an
    /// optimistic like stays visible until the server agrees.
    private func mergeLiked(remote: [Song]) -> [Song] {
        var seen = Set(remote.map(\.id))
        var result = remote
        for song in library.songs(ids: library.likedSongIDs) where seen.insert(song.id).inserted {
            result.append(song)
        }
        return result
    }

    /// Loads the remote track list (Liked Songs included) and reports failures
    /// in-place rather than throwing them at the view.
    ///
    /// The account write goes through `setAccountLikedSongs`, whose merge policy
    /// keeps a just-made optimistic like from being undone by a lagging read.
    private func loadRemoteIfNeeded(_ playlist: Playlist) async {
        guard fetchesRemote else { return }
        isLoadingRemote = true
        remoteMessage = nil
        do {
            let songs = try await auth.client.songs(in: playlist)
            remoteSongs = songs
            if isLikedCollection {
                library.setAccountLikedSongs(songs)
            }
            if songs.isEmpty {
                remoteMessage = "This playlist has no tracks."
            }
        } catch {
            remoteSongs = []
            remoteMessage = error.localizedDescription
        }
        isLoadingRemote = false
    }

    /// Same multi-select bundle as the Library grid, plus the playlist needed
    /// to remove the selection from this list.
    private func songRowSelection(for song: Song, in songs: [Song]) -> SongRowSelection {
        SongRowSelection(
            isSelected: songSelection.contains(song.id),
            isBatch: songSelection.count > 1 && songSelection.contains(song.id),
            selectedSongs: songs.filter { songSelection.contains($0.id) },
            removeFrom: canRemoveSongs ? playlist : nil,
            onIntent: { intent in
                RowSelection.apply(
                    intent, id: song.id, order: songs.map(\.id),
                    selected: &songSelection, anchor: &songAnchor
                )
            }
        )
    }
}
