import Foundation

/// `LibraryStore` account-library layer: the in-memory account caches
/// (playlists / albums / artists), their derived state, and follow / collect.
extension LibraryStore {
    /// Sidebar / Library Playlists: the account's owned lists once the account
    /// library has loaded, otherwise the on-disk local lists. Empty when signed out.
    var displayedPlaylists: [Playlist] {
        guard currentUserID != nil else { return [] }
        return hasAccountLibrary ? accountOwnedPlaylists.filter { $0.kind != .liked } : playlists
    }

    var displayedCollectedPlaylists: [Playlist] {
        hasAccountLibrary ? accountCollectedPlaylists : []
    }

    var allAlbums: [Album] {
        hasAccountLibrary ? accountAlbums : []
    }

    var allArtists: [Artist] {
        hasAccountLibrary ? accountArtists : []
    }

    func album(id: String) -> Album? {
        allAlbums.first { $0.id == id }
    }

    func artist(id: String) -> Artist? {
        allArtists.first { $0.id == id }
    }

    // MARK: - Artist follows / playlist collection (cloud)

    func isFollowing(_ artist: Artist) -> Bool {
        guard currentUserID != nil else { return false }
        let key = Self.artistKey(artist)
        return accountArtists.contains { Self.artistKey($0) == key }
    }

    /// Optimistically reflects a follow / unfollow so the detail button updates
    /// without waiting for a full account refresh.
    func setArtistFollowed(_ artist: Artist, followed: Bool) {
        guard currentUserID != nil else { return }
        let key = Self.artistKey(artist)
        if followed {
            if !accountArtists.contains(where: { Self.artistKey($0) == key }) {
                accountArtists.insert(artist, at: 0)
            }
        } else {
            accountArtists.removeAll { Self.artistKey($0) == key }
        }
    }

    func requestToggleFollow(_ artist: Artist) {
        if let cloudToggleFollow {
            Task { await cloudToggleFollow(artist) }
        }
    }

    /// A browsing (`.featured`) playlist is collected when the account library
    /// holds a matching row, so state is derived rather than stored twice.
    func isFavorite(_ playlist: Playlist) -> Bool {
        guard currentUserID != nil else { return false }
        return collectedPlaylist(matching: playlist) != nil
    }

    /// Finds the account's collected copy of a browsed playlist. Matches on the
    /// global collection id, since the browsed row's own id is not the account's.
    func collectedPlaylist(matching playlist: Playlist) -> Playlist? {
        let gid = playlist.globalCollectionID ?? playlist.id
        guard !gid.isEmpty else { return nil }
        return accountCollectedPlaylists.first {
            $0.id == gid || $0.globalCollectionID == gid
        }
    }

    func requestToggleFavorite(_ playlist: Playlist) {
        if let cloudToggleFavoritePlaylist {
            Task { await cloudToggleFavoritePlaylist(playlist) }
        }
    }

    /// Identity for an artist across search rows and account rows: Kugou's own
    /// singer id when present, otherwise the parsed id.
    private static func artistKey(_ artist: Artist) -> String {
        artist.singerID ?? artist.id
    }

    /// Replaces the account cache with a fresh snapshot. The cloud is
    /// authoritative, so this is a wholesale assignment rather than a merge.
    func applyAccountLibrary(_ library: UserLibrary) {
        accountOwnedPlaylists = library.ownedPlaylists
        accountCollectedPlaylists = library.collectedPlaylists
        accountAlbums = library.collectedAlbums
        accountArtists = library.followedArtists
        accountLikedPlaylist = library.likedPlaylist
        hasAccountLibrary = true
        accountError = nil
    }

    /// Applies a liked-list read. The account is the source of truth, but
    /// `added` / `removed` carry a write that just happened and may still be
    /// catching up on the server, so a lagging read must not undo it.
    func setAccountLikedSongs(_ songs: [Song], keeping added: [Song] = [], removing removed: [Song] = []) {
        let removedIDs = Set(removed.map(\.id))
        var merged = songs.filter { !removedIDs.contains($0.id) }
        var seen = Set(merged.map(\.id))
        for song in added where seen.insert(song.id).inserted {
            merged.insert(song, at: 0)
        }
        accountLikedSongs = merged
        // `likedSongIDs` follows the merged result so the local mirror agrees with
        // the account instead of adding a second, drifting source of likes.
        likedSongIDs = merged.map(\.id)
        for song in merged {
            remember(song)
        }
        save()
    }

    /// Sign-out: drop the account cache. The per-user buckets are untouched, so
    /// signing back in restores this user's likes / recents / pins.
    func clearAccountLibrary() {
        accountOwnedPlaylists = []
        accountCollectedPlaylists = []
        accountAlbums = []
        accountArtists = []
        accountLikedPlaylist = nil
        accountLikedSongs = []
        hasAccountLibrary = false
        accountError = nil
        accountActionMessage = nil
        isRefreshingAccount = false
    }
}
