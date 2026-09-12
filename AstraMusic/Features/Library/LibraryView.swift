import SwiftUI

/// Tabs of the Library screen.
///
/// The raw values are the picker labels. There is deliberately no "On this Mac"
/// case: local lists surface under Playlists rather than as their own tab.
enum LibrarySection: String, CaseIterable, Identifiable {
    case liked = "Liked Songs"
    case albums = "Albums"
    case artists = "Artists"
    case playlists = "Playlists"
    case recent = "Recent"

    /// Stable `ForEach` identity; the raw value is unique per case.
    var id: String { rawValue }
}

/// Library root: the five-tab browser behind the sidebar's Library entry.
///
/// Owns no playback state. Play and navigation are injected as callbacks by the
/// parent, which owns the middle column's `NavigationStack` path and the
/// `PlayerStore`, so this view never reaches into the playback layer.
struct LibraryView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    /// Playback and route pushes are delegated upward: `onPlay` hands a song to
    /// the player, and the `onOpen*` closures append a detail route.
    var onPlay: (Song) -> Void
    var onOpenAlbum: (Album) -> Void
    var onOpenArtist: (Artist) -> Void
    var onOpenPlaylist: (Playlist) -> Void

    /// Selected tab, view-local: it resets when the Library root is rebuilt.
    @State private var section: LibrarySection = .liked
    /// Notes-style multi-select for the song / playlist lists.
    ///
    /// Both sets hold canonical ids (`Song.id` / `Playlist.id`); the anchor is
    /// the row a shift-click extends the range from.
    @State private var songSelection: Set<String> = []
    @State private var songAnchor: Int?
    @State private var playlistSelection: Set<String> = []
    @State private var playlistAnchor: Int?

    var body: some View {
        Group {
            // No guest mode: the entire Library sits behind sign-in.
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in to view your library", systemImage: "square.stack")
            } else {
                VStack(spacing: 0) {
                    Picker("Library", selection: $section) {
                        ForEach(LibrarySection.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)

                    // Account lists are in-memory only, so this strip is the sole
                    // signal that a refresh is in flight or has failed.
                    if library.isRefreshingAccount {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.bottom, 8)
                    } else if let message = library.accountError, !message.isEmpty {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 8)
                    }

                    Group {
                        switch section {
                        case .liked:
                            songList(library.likedSongs, empty: "No liked songs yet.", inLikedCollection: true)
                        case .albums:
                            albumGrid(library.allAlbums, empty: "No albums.")
                        case .artists:
                            artistList(library.allArtists, empty: "No artists.")
                        case .playlists:
                            playlistList
                        case .recent:
                            songList(library.recentSongs, empty: "Nothing played yet.")
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("Library")
        .escClearsSelection(
            isActive: { !songSelection.isEmpty || !playlistSelection.isEmpty },
            clear: {
                songSelection = []
                songAnchor = nil
                playlistSelection = []
                playlistAnchor = nil
            }
        )
    }

    /// Shared song list for the Liked Songs and Recent tabs.
    ///
    /// `inLikedCollection` is forwarded to `SongRow` so unliking reads like a
    /// remove action; the callers differ only in which store list they pass.
    private func songList(_ songs: [Song], empty: String, inLikedCollection: Bool = false) -> some View {
        Group {
            if songs.isEmpty {
                ContentUnavailableView(empty, systemImage: "music.note")
            } else {
                List(songs) { song in
                    SongRow(
                        song: song,
                        selection: songRowSelection(for: song, in: songs),
                        inLikedCollection: inLikedCollection
                    ) { onPlay(song) }
                }
                .hidesScrollIndicators()
            }
        }
    }

    /// Read-only album grid.
    ///
    /// Album collect/uncollect was intentionally not implemented in this build,
    /// so no tile exposes collect actions. A tap pushes the album route.
    private func albumGrid(_ albums: [Album], empty: String) -> some View {
        Group {
            if albums.isEmpty {
                ContentUnavailableView(empty, systemImage: "square.stack.fill")
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(albums) { album in
                            VStack(alignment: .leading, spacing: 8) {
                                CoverTile(album: album)
                                Text(album.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(album.artistName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: Theme.coverCard, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenAlbum(album) }
                        }
                    }
                    .padding(24)
                }
                .hidesScrollIndicators()
            }
        }
    }

    /// Read-only roster of the account library's followed artists.
    private func artistList(_ artists: [Artist], empty: String) -> some View {
        Group {
            if artists.isEmpty {
                ContentUnavailableView(empty, systemImage: "person.2")
            } else {
                List(artists) { artist in
                    HStack(spacing: 12) {
                        CoverTile(artist: artist, size: 40)
                        Text(artist.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onOpenArtist(artist)
                    }
                }
                .hidesScrollIndicators()
            }
        }
    }

    /// Playlists tab: Created above Collected, both from the account library.
    ///
    /// An empty grid here can mean "not loaded yet" as easily as "empty":
    /// account lists are in-memory only and rebuilt on refresh.
    private var playlistList: some View {
        let created = library.displayedPlaylists
        let collected = library.displayedCollectedPlaylists
        return Group {
            if created.isEmpty, collected.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list")
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        if !created.isEmpty {
                            playlistSection("Created", playlists: created)
                        }
                        if !collected.isEmpty {
                            playlistSection("Collected", playlists: collected)
                        }
                    }
                    .padding(24)
                }
                .hidesScrollIndicators()
            }
        }
    }

    /// Titled grid shared by the Created and Collected sections.
    private func playlistSection(_ title: String, playlists: [Playlist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                ForEach(playlists) { playlist in
                    playlistCell(playlist)
                }
            }
        }
    }

    /// One playlist tile with Notes-style selection and a single/batch menu.
    ///
    /// A plain click opens the playlist; ⌘/shift clicks adjust the selection
    /// instead, and the border drawn above is the purple selection ring.
    private func playlistCell(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverTile(symbol: playlist.artworkSymbol, template: playlist.artworkTemplate)
                .overlay {
                    if playlistSelection.contains(playlist.id) {
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                    }
                }
            Text(playlist.name)
                .font(.headline)
                .lineLimit(1)
                .foregroundStyle(.primary)
            Text(playlist.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: Theme.coverCard, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            let intent = NSEvent.modifierFlags.rowSelectIntent
            if intent == .play { onOpenPlaylist(playlist) }
            RowSelection.apply(
                intent, id: playlist.id, order: playlistOrder.map(\.id),
                selected: &playlistSelection, anchor: &playlistAnchor
            )
        }
        .contextMenu {
            if playlistSelection.count > 1 && playlistSelection.contains(playlist.id) {
                PlaylistBatchMenu(playlists: selectedPlaylists)
            } else {
                PlaylistContextActions(playlist: playlist)
            }
        }
        .focusEffectDisabled()
    }

    /// Order used for shift-click ranges. It must stay in the same order as the
    /// rendered grid (Created, then Collected) or a range will not match what
    /// the user sees.
    private var playlistOrder: [Playlist] {
        library.displayedPlaylists + library.displayedCollectedPlaylists
    }

    /// Selected tiles as objects, in visible order, for `PlaylistBatchMenu`.
    private var selectedPlaylists: [Playlist] {
        playlistOrder.filter { playlistSelection.contains($0.id) }
    }

    /// Bundles the multi-select state a song row needs to render and to run the
    /// shared `RowSelection` state machine on click.
    private func songRowSelection(for song: Song, in songs: [Song]) -> SongRowSelection {
        SongRowSelection(
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
