import Foundation

/// `LibraryStore` local playlist mutations and their cloud-routed requests:
/// lookup, add / remove / rename / delete, and pinning.
extension LibraryStore {
    /// Pinned playlists from the account library, in sidebar order: created
    /// (owned) first, then collected.
    var pinnedPlaylists: [Playlist] {
        guard currentUserID != nil else { return [] }
        let pinned = Set(pinnedPlaylistIDs)
        return (displayedPlaylists + displayedCollectedPlaylists).filter { pinned.contains($0.id) }
    }

    /// Resolves a playlist by id. `"liked"` is a synthetic id for the liked
    /// songs row; everything else is searched across the displayed, local, and
    /// raw account lists so a detail view keeps working before/after a refresh.
    func playlist(id: String) -> Playlist? {
        if id == "liked" { return accountLikedPlaylist }
        return displayedPlaylists.first { $0.id == id }
            ?? displayedCollectedPlaylists.first { $0.id == id }
            ?? playlists.first { $0.id == id }
            ?? accountOwnedPlaylists.first { $0.id == id }
            ?? accountCollectedPlaylists.first { $0.id == id }
    }

    func requestAdd(_ song: Song, to playlist: Playlist) {
        requestAdd([song], to: playlist)
    }

    func requestAdd(_ songs: [Song], to playlist: Playlist) {
        if let cloudAddToPlaylist {
            Task { await cloudAddToPlaylist(songs, playlist) }
        } else {
            for song in songs { add(song, to: playlist) }
        }
    }

    func requestRemove(_ song: Song, from playlist: Playlist) {
        requestRemove([song], from: playlist)
    }

    func requestRemove(_ songs: [Song], from playlist: Playlist) {
        if let cloudRemoveFromPlaylist {
            Task { await cloudRemoveFromPlaylist(songs, playlist) }
        } else {
            for song in songs { remove(song, from: playlist) }
        }
    }

    func requestDeletePlaylist(_ playlist: Playlist) {
        if let cloudDeletePlaylist {
            Task { await cloudDeletePlaylist(playlist) }
        } else {
            deletePlaylist(id: playlist.id)
        }
    }

    func isPinned(_ playlist: Playlist) -> Bool {
        pinnedPlaylistIDs.contains(playlist.id)
    }

    /// Only collected / owned lists can be pinned. Pins are rendered from the
    /// account library, so an on-disk local list's pin would never be shown.
    func togglePinned(_ playlist: Playlist) {
        guard currentUserID != nil,
              playlist.kind == .collected || playlist.kind == .owned else { return }
        if let index = pinnedPlaylistIDs.firstIndex(of: playlist.id) {
            pinnedPlaylistIDs.remove(at: index)
        } else {
            pinnedPlaylistIDs.append(playlist.id)
        }
        if let userID = currentUserID {
            pinnedPlaylistIDsByUser[userID] = pinnedPlaylistIDs
        }
        save()
    }

    /// Drops a playlist's pin (by list id too) — used when it is uncollected or
    /// deleted in the cloud, so a stale pin doesn't reattach on re-collect.
    func unpin(_ playlist: Playlist) {
        var ids: Set<String> = [playlist.id]
        if let listID = playlist.listID { ids.insert(listID) }
        let before = pinnedPlaylistIDs.count
        pinnedPlaylistIDs.removeAll { ids.contains($0) }
        guard pinnedPlaylistIDs.count != before else { return }
        if let userID = currentUserID {
            pinnedPlaylistIDsByUser[userID] = pinnedPlaylistIDs
        }
        save()
    }

    func renamePlaylist(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = trimmed
        save()
    }

    /// Deletes a local playlist. `"liked"` is not deletable.
    func deletePlaylist(id: String) {
        guard id != "liked" else { return }
        playlists.removeAll { $0.id == id }
        save()
    }

    /// Adds to a *local* playlist. Account playlists go through the cloud instead
    /// (`requestAdd`), which is why this only touches `playlists`.
    func add(_ song: Song, to playlist: Playlist) {
        guard currentUserID != nil else { return }
        guard playlist.id != "liked" else { return }
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        remember(song)
        guard !playlists[index].songIDs.contains(song.id) else { return }
        playlists[index].songIDs.append(song.id)
        save()
    }

    func remove(_ song: Song, from playlist: Playlist) {
        guard let index = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[index].songIDs.removeAll { $0 == song.id }
        save()
    }
}
