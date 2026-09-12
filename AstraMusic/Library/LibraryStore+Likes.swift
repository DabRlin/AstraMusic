import Foundation

/// `LibraryStore` likes and recents: the per-user liked/recent song lists, the
/// remembered-song cache lookups, and the local / cloud like write paths.
extension LibraryStore {
    /// Liked songs, account first then anything only known locally, de-duplicated.
    /// Empty while signed out: likes are not a guest-visible thing.
    var likedSongs: [Song] {
        guard currentUserID != nil else { return [] }
        var seen = Set<String>()
        var result: [Song] = []
        for song in accountLikedSongs + songs(ids: likedSongIDs) {
            if seen.insert(song.id).inserted {
                result.append(song)
            }
        }
        return result
    }

    var recentSongs: [Song] {
        guard currentUserID != nil else { return [] }
        return songs(ids: recentSongIDs)
    }

    /// Looks a song up by canonical id: the remembered cache first (covers,
    /// hashes), then the account liked list.
    func song(id: String) -> Song? {
        rememberedSongs[id]
            ?? accountLikedSongs.first { $0.id == id }
    }

    func remember(_ song: Song) {
        rememberedSongs[song.id] = song
    }

    func songs(ids: [String]) -> [Song] {
        ids.compactMap(song(id:))
    }

    func songs(in playlist: Playlist) -> [Song] {
        songs(ids: playlist.songIDs)
    }

    func isLiked(_ song: Song) -> Bool {
        guard currentUserID != nil else { return false }
        return accountLikedSongs.contains(where: { $0.id == song.id }) || likedSongIDs.contains(song.id)
    }

    /// True when every song is liked — used to label a bulk menu item.
    func isLiked(_ songs: [Song]) -> Bool {
        guard !songs.isEmpty else { return false }
        return songs.allSatisfy { isLiked($0) }
    }

    /// Applies an optimistic local like. Mirrors into the account list too, so
    /// the UI is correct before the cloud read confirms it.
    func like(_ song: Song) {
        guard currentUserID != nil else { return }
        remember(song)
        if !likedSongIDs.contains(song.id) {
            likedSongIDs.insert(song.id, at: 0)
        }
        if hasAccountLibrary, !accountLikedSongs.contains(where: { $0.id == song.id }) {
            accountLikedSongs.insert(song, at: 0)
        }
        save()
    }

    func unlike(_ song: Song) {
        likedSongIDs.removeAll { $0 == song.id }
        accountLikedSongs.removeAll { $0.id == song.id }
        save()
    }

    func toggleLike(_ song: Song) {
        if isLiked(song) {
            unlike(song)
        } else {
            like(song)
        }
    }

    func requestToggleLike(_ song: Song) {
        requestToggleLike([song])
    }

    /// Routes a like through the cloud when one is attached, otherwise applies it
    /// locally. The closures are nil while signed out (or in previews), which is
    /// exactly when a local-only write is the right answer.
    func requestToggleLike(_ songs: [Song]) {
        if let cloudToggleLike {
            Task { await cloudToggleLike(songs) }
        } else {
            for song in songs { toggleLike(song) }
        }
    }

    /// Records a play. Local only — there is no `/user/listen` call — and capped
    /// by `recentLimit`, with a repeat moving the track back to the front.
    func recordPlay(_ song: Song) {
        remember(song)
        guard let userID = currentUserID else { return }
        recentSongIDs.removeAll { $0 == song.id }
        recentSongIDs.insert(song.id, at: 0)
        if recentSongIDs.count > Self.recentLimit {
            recentSongIDs = Array(recentSongIDs.prefix(Self.recentLimit))
        }
        recentSongIDsByUser[userID] = recentSongIDs
        save()
    }
}
