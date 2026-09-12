import SwiftUI

/// Segmented tabs of the artist detail screen.
enum ArtistSection: String, CaseIterable, Identifiable {
    case songs = "Songs"
    case albums = "Albums"

    var id: String { rawValue }
}

/// Artist route detail: a header plus lazy Songs / Albums tabs.
///
/// Follow state is derived from the account library and toggled through
/// `LibraryStore`'s cloud closure, so this view never holds `AuthStore`.
struct ArtistDetailView: View {
    @Environment(PlayerStore.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    /// Carried by the route.
    let artist: Artist
    var onPlay: (Song) -> Void
    var onOpenAlbum: (Album) -> Void

    @State private var section: ArtistSection = .songs
    /// Songs and albums are fetched independently; each pair tracks loading and
    /// an error / empty hint so one tab's failure does not clear the other.
    @State private var songs: [Song] = []
    @State private var message: String?
    @State private var isLoading = false
    @State private var albums: [Album] = []
    @State private var albumsMessage: String?
    @State private var isLoadingAlbums = false
    /// Notes-style multi-select for the track list.
    @State private var songSelection: Set<String> = []
    @State private var songAnchor: Int?

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(title: "Sign in to see this artist", systemImage: "person.fill")
                    .navigationTitle("Artist")
            } else {
                VStack(spacing: 0) {
                    header(artist)

                    Picker("Section", selection: $section) {
                        ForEach(ArtistSection.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)

                    Group {
                        switch section {
                        case .songs: songsList
                        case .albums: albumsGrid
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .navigationTitle(artist.name)
                // Songs load with the artist; albums only when their tab is
                // opened (`loadAlbums` also guards a refetch on re-entry).
                .task(id: artist.id) {
                    await loadSongs(artist)
                }
                .task(id: section) {
                    guard section == .albums else { return }
                    await loadAlbums(artist)
                }
                .escClearsSelection(
                    isActive: { !songSelection.isEmpty },
                    clear: {
                        songSelection = []
                        songAnchor = nil
                    }
                )
            }
        }
    }

    private func header(_ artist: Artist) -> some View {
        DetailHeader(
            title: artist.name,
            canPlay: !songs.isEmpty,
            onPlay: { player.play(songs: songs) },
            cover: { CoverTile(artist: artist, size: 96) },
            actions: {
                // Derived state: `isFollowing` reads the account library, and
                // the toggle goes through the cloud closure, with optimistic
                // update/rollback handled inside `LibraryStore`.
                DetailToggleButton(
                    title: library.isFollowing(artist) ? "Following" : "Follow",
                    systemImage: library.isFollowing(artist) ? "checkmark.circle.fill" : "person.badge.plus"
                ) {
                    library.requestToggleFollow(artist)
                }
            }
        )
        .padding(.horizontal, 20)
    }

    /// Precedence matters: an error/empty hint only shows while the list is
    /// still empty, so a failed refresh never hides already-fetched songs.
    private var songsList: some View {
        DetailContent(
            isEmpty: songs.isEmpty,
            isLoading: isLoading,
            message: message,
            isCentered: true,
            empty: { ContentUnavailableView("No songs", systemImage: "music.note") }
        ) {
            List(songs) { song in
                SongRow(song: song, selection: songRowSelection(for: song, in: songs)) {
                    player.play(songs: songs, startingAt: song)
                }
            }
            .hidesScrollIndicators()
        }
    }

    /// Same loading / error / empty precedence as `songsList`.
    private var albumsGrid: some View {
        DetailContent(
            isEmpty: albums.isEmpty,
            isLoading: isLoadingAlbums,
            message: albumsMessage,
            isCentered: true,
            empty: { ContentUnavailableView("No albums", systemImage: "square.stack.fill") }
        ) {
            ScrollView(showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                    ForEach(albums) { album in
                        Button {
                            onOpenAlbum(album)
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                CoverTile(album: album)
                                Text(album.title)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(album.year.map(String.init) ?? album.artistName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: Theme.coverCard, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(24)
            }
            .hidesScrollIndicators()
        }
    }

    /// Fetches the artist's songs and turns failures (including risk / captcha
    /// errors) into the inline `message`.
    private func loadSongs(_ artist: Artist) async {
        isLoading = true
        message = nil
        do {
            songs = try await auth.client.songs(by: artist)
            if songs.isEmpty { message = "No tracks for this artist." }
        } catch {
            songs = []
            message = error.localizedDescription
        }
        isLoading = false
    }

    /// Lazy and idempotent: the guard keeps flipping back to the tab from
    /// issuing another request.
    private func loadAlbums(_ artist: Artist) async {
        guard albums.isEmpty, !isLoadingAlbums else { return }
        isLoadingAlbums = true
        albumsMessage = nil
        do {
            albums = try await auth.client.albums(by: artist)
            if albums.isEmpty { albumsMessage = "No albums for this artist." }
        } catch {
            albums = []
            albumsMessage = error.localizedDescription
        }
        isLoadingAlbums = false
    }

    /// Multi-select for the fetched song list.
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
