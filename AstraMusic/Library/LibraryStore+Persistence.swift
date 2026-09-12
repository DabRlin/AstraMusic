import Foundation

/// `LibraryStore` persistence and per-user switching: loading / saving
/// `library.json`, applying a snapshot, and the legacy-list migrations.
extension LibraryStore {
    /// Switches the active account.
    ///
    /// Flushes the outgoing user's mirror into their bucket, then loads the
    /// incoming user's (or empties the mirror for a guest). This is why the
    /// un-suffixed lists must never be written to directly — they are a view of
    /// one bucket, not the storage.
    func setCurrentUser(_ userID: String?) {
        var shouldSave = false
        if let oldID = currentUserID, oldID != userID {
            recentSongIDsByUser[oldID] = recentSongIDs
            pinnedPlaylistIDsByUser[oldID] = pinnedPlaylistIDs
            likedSongIDsByUser[oldID] = likedSongIDs
            shouldSave = true
        }
        currentUserID = userID
        if let userID {
            recentSongIDs = recentSongIDsByUser[userID] ?? []
            pinnedPlaylistIDs = pinnedPlaylistIDsByUser[userID] ?? []
            likedSongIDs = likedSongIDsByUser[userID] ?? []
        } else {
            recentSongIDs = []
            pinnedPlaylistIDs = []
            likedSongIDs = []
        }
        if migrateLegacyRecentsIfNeeded() {
            shouldSave = true
        }
        if migrateLegacyLikesIfNeeded() {
            shouldSave = true
        }
        if shouldSave {
            save()
        }
    }

    func load() {
        let folder = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            seed()
            save()
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
            apply(snapshot)
        } catch {
            // Unreadable or stale-schema file: start clean rather than crash.
            seed()
            save()
        }
    }

    private func apply(_ snapshot: LibrarySnapshot) {
        // Rebuild the song cache with canonical ids, remembering how the ids in
        // the file map onto them so every stored list can be re-keyed. Older
        // builds identified tracks by their HQ hash, which split one song in two.
        var remap: [String: String] = [:]
        var rebuilt: [String: Song] = [:]
        for song in snapshot.rememberedSongs ?? [] {
            let normalized = song.normalized()
            remap[song.id] = normalized.id
            rebuilt[normalized.id] = normalized
        }
        rememberedSongs = rebuilt

        func remapIDs(_ ids: [String]) -> [String] {
            var seen = Set<String>()
            var result: [String] = []
            for id in ids {
                let mapped = remap[id] ?? id
                if seen.insert(mapped).inserted { result.append(mapped) }
            }
            return result
        }

        likedSongIDsByUser = (snapshot.likedSongIDsByUser ?? [:]).mapValues { remapIDs($0) }
        recentSongIDsByUser = (snapshot.recentSongIDsByUser ?? [:]).mapValues { remapIDs($0) }
        pinnedPlaylistIDsByUser = snapshot.pinnedPlaylistIDsByUser ?? [:]
        // The mirrors stay empty until `setCurrentUser` picks a bucket.
        likedSongIDs = []
        recentSongIDs = []
        pinnedPlaylistIDs = []

        // Account-agnostic lists from before per-user buckets fold into the
        // current account on the next `setCurrentUser`.
        if !snapshot.likedSongIDs.isEmpty {
            legacyGlobalLikes = remapIDs(snapshot.likedSongIDs)
        }
        if !snapshot.recentSongIDs.isEmpty {
            legacyGlobalRecents = remapIDs(snapshot.recentSongIDs)
        }
        // Only local playlists are ours; anything else in the file is a leftover
        // from a build that persisted account lists, and is dropped.
        playlists = snapshot.playlists
            .filter { $0.id != "liked" && $0.kind == .local }
            .map { playlist in
                var copy = playlist
                copy.songIDs = remapIDs(playlist.songIDs)
                return copy
            }
    }

    func seed() {
        playlists = []
        likedSongIDs = []
        likedSongIDsByUser = [:]
        recentSongIDs = []
        recentSongIDsByUser = [:]
        pinnedPlaylistIDs = []
        pinnedPlaylistIDsByUser = [:]
        legacyGlobalRecents = nil
        legacyGlobalLikes = nil
    }

    /// Attributes the file's old account-agnostic recents to the first account
    /// that signs in, unless that account already has recents of its own.
    private func migrateLegacyRecentsIfNeeded() -> Bool {
        guard let legacy = legacyGlobalRecents else { return false }
        legacyGlobalRecents = nil
        guard !legacy.isEmpty else { return false }
        if let userID = currentUserID, recentSongIDsByUser[userID]?.isEmpty != false {
            recentSongIDsByUser[userID] = legacy
            recentSongIDs = legacy
        }
        return true
    }

    /// Counterpart of `migrateLegacyRecentsIfNeeded` for the legacy likes list.
    private func migrateLegacyLikesIfNeeded() -> Bool {
        guard let legacy = legacyGlobalLikes else { return false }
        legacyGlobalLikes = nil
        guard !legacy.isEmpty else { return false }
        if let userID = currentUserID, likedSongIDsByUser[userID]?.isEmpty != false {
            likedSongIDsByUser[userID] = legacy
            likedSongIDs = legacy
        }
        return true
    }

    /// Persists local state. Flushes the current user's mirror into their bucket
    /// first, then writes only local playlists — account lists must never reach
    /// the file. Atomic write, and a failure is swallowed: this is a cache.
    func save() {
        guard persistToDisk else { return }
        if let userID = currentUserID {
            recentSongIDsByUser[userID] = recentSongIDs
            pinnedPlaylistIDsByUser[userID] = pinnedPlaylistIDs
            likedSongIDsByUser[userID] = likedSongIDs
        }
        let snapshot = LibrarySnapshot(
            likedSongIDs: legacyGlobalLikes ?? [],
            likedSongIDsByUser: likedSongIDsByUser,
            recentSongIDs: legacyGlobalRecents ?? [],
            playlists: playlists.filter { $0.kind == .local },
            rememberedSongs: Array(rememberedSongs.values),
            recentSongIDsByUser: recentSongIDsByUser,
            pinnedPlaylistIDsByUser: pinnedPlaylistIDsByUser
        )
        do {
            let folder = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Local cache only; keep working in memory if disk is unavailable.
        }
    }

    /// `~/Library/Application Support/AstraMusic/library.json` (or the sandboxed
    /// container equivalent, when the app is sandboxed).
    static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("AstraMusic", isDirectory: true)
            .appendingPathComponent("library.json")
    }
}
