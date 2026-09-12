import Foundation

/// The data boundary the UI talks to.
///
/// Everything above this protocol (views and stores) only deals in `Song`,
/// `Playlist`, `Album`, and `Artist`; everything below it knows about the local
/// KuGouMusicApi sidecar, HTTP, and Kugou's payload quirks. Swapping the
/// implementation is the intended way to change the backend.
///
/// Implementations throw `APIError`. Reads mostly work while signed out;
/// every mutating call (`follow`, `collectPlaylist`, `add`, `removeTrack`,
/// `deletePlaylist`) needs a session.
protocol MusicClient: Sendable {
    /// Home "For you" feed (`/everyday/recommend`).
    func dailyRecommend() async throws -> [Song]

    /// Ranked / curated playlists for the Home discovery row (`/top/playlist`).
    func recommendedPlaylists() async throws -> [Playlist]

    /// Tracks of a playlist.
    ///
    /// Uses `playlist.trackFetchID` (the global collection id) — **not**
    /// `listID`. Kugou's `/playlist/track/all` 502s when handed a `listid`.
    func songs(in playlist: Playlist) async throws -> [Song]

    /// Lyrics for a track, already flattened to one entry per displayed line.
    /// KRC word-level timings are collapsed to line start times; LRC is the fallback.
    func lyrics(for song: Song) async throws -> [LyricLine]

    /// Paged search. `type` selects the result kind — see `SearchType`.
    func search(keywords: String, type: SearchType, page: Int, pageSize: Int) async throws -> SearchPage

    /// Resolves a playable CDN URL for a track.
    ///
    /// Requires a signed-in session (there are no guest previews), and the result
    /// is deliberately never persisted: URLs are short-lived, so every play
    /// re-resolves via `/privilege/lite` → `/song/url`.
    func playbackURL(for song: Song) async throws -> URL

    /// The signed-in account's library: liked, created, collected, albums, artists.
    func userLibrary() async throws -> UserLibrary

    /// Tracks of an album. Kugou models an album as a playlist row with `authors` set.
    func songs(in album: Album) async throws -> [Song]

    /// An artist's top tracks.
    func songs(by artist: Artist) async throws -> [Song]

    /// An artist's albums.
    func albums(by artist: Artist) async throws -> [Album]

    /// Follows an artist in the account library.
    ///
    /// `artistID` is the account-library id — the `/user/follow` row whose
    /// `source == 7` — not a search-result id.
    func follow(artistID: String) async throws

    /// Unfollows an artist; counterpart of `follow(artistID:)`.
    func unfollow(artistID: String) async throws

    /// Saves someone else's playlist into the account library.
    func collectPlaylist(name: String, listCreateUserID: String, globalCollectionID: String) async throws

    /// Appends one track to a playlist the user owns.
    /// `listID` is the mutation id (`/playlist/tracks/add`), not the track-fetch id.
    func add(song: Song, toListID listID: String) async throws

    /// Removes one track from a playlist the user owns.
    ///
    /// `fileid` is the playlist-row id. Kugou needs it to remove the right row;
    /// without one the removal can only be applied locally.
    func removeTrack(fileid: String, fromListID listID: String) async throws

    /// Appends several tracks in a single call (bulk "add to playlist").
    func add(songs: [Song], toListID listID: String) async throws

    /// Removes several tracks in a single call (bulk "remove from playlist").
    func removeTracks(fileIDs: [String], fromListID listID: String) async throws

    /// Deletes a playlist the user owns.
    func deletePlaylist(listID: String) async throws
}

/// Search result kind.
///
/// `rawValue` is sent verbatim as the sidecar's `type` query parameter, so the
/// case names must stay in sync with the API. Note the naming mismatch between
/// the API and the UI: `.author` is an artist, `.special` is a playlist.
enum SearchType: String, CaseIterable, Identifiable, Sendable {
    case song
    case album
    case author
    case special

    var id: String { rawValue }
    var title: String {
        switch self {
        case .song: "Songs"
        case .album: "Albums"
        case .author: "Artists"
        case .special: "Playlists"
        }
    }
    var systemImage: String {
        switch self {
        case .song: "music.note"
        case .album: "square.stack.fill"
        case .author: "person.fill"
        case .special: "music.note.list"
        }
    }
}

/// One row of a mixed search result list.
///
/// Exactly one of `song` / `album` / `artist` / `playlist` is set, matching
/// `type`. `song` carries a `SearchSong` rather than a `Song` because search
/// rows lack the identity fields playback needs.
struct SearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let type: SearchType
    var subtitle: String
    var song: SearchSong?
    var album: Album?
    var artist: Artist?
    var playlist: Playlist?
}

/// One page of search results.
///
/// Song searches build `results` from `songs` rows; every other kind fills
/// `results` directly. `total` is `0` when the sidecar does not report one.
struct SearchPage: Sendable {
    var results: [SearchResult]
    var total: Int
    var page: Int
    var pageSize: Int

    /// Falls back to "a full page implies there is another" when there is no total.
    var hasMore: Bool {
        if total > 0 { return page * pageSize < total }
        return results.count >= pageSize
    }

    init(songs: [SearchSong], total: Int, page: Int, pageSize: Int) {
        self.results = songs.map {
            SearchResult(id: $0.id, type: .song, subtitle: $0.artistName, song: $0, album: nil, artist: nil, playlist: nil)
        }
        self.total = total
        self.page = page
        self.pageSize = pageSize
    }

    init(results: [SearchResult], total: Int, page: Int, pageSize: Int) {
        self.results = results
        self.total = total
        self.page = page
        self.pageSize = pageSize
    }
}
