import Foundation
import Observation

/// Owns the account: device registration, login state, and every cloud mutation.
///
/// Marked `@MainActor` so SwiftUI can observe it directly. It is also the only
/// place that talks to the account endpoints on behalf of the library — see
/// `attach(_:player:)` for why those calls arrive as closures rather than as
/// direct references from views.
@Observable
@MainActor
final class AuthStore {
    var user: UserSession?
    var device: DeviceInfo?
    /// Last failure, already phrased for display.
    var lastError: String?
    /// Whether the local sidecar answered. Drives the "start the local API
    /// sidecar" messaging instead of showing an empty screen with no explanation.
    var apiReachable = false

    /// The account client. Typed as the composition of the metadata surface
    /// (`MusicClient`) and the login-only surface (`LoginClient`) so no view
    /// depends on the concrete `KugouMusicClient`.
    let client: any MusicClient & LoginClient = KugouMusicClient()
    /// Weak to avoid a retain cycle: the library and player outlive useful views,
    /// and both are injected into the environment too.
    @ObservationIgnored
    weak var library: LibraryStore?
    @ObservationIgnored
    weak var player: PlayerStore?

    /// Wires up the cloud write paths.
    ///
    /// `LibraryStore` exposes click handlers instead of holding `AuthStore`, so
    /// song rows and menus can trigger a cloud write without gaining a reference
    /// to the account layer. These closures are that indirection, installed once
    /// at launch.
    func attach(_ library: LibraryStore, player: PlayerStore) {
        self.library = library
        self.player = player
        player.setUser(user?.userID)
        library.setCurrentUser(user?.userID)
        library.cloudToggleLike = { [weak self] songs in
            await self?.toggleLike(songs)
        }
        library.cloudAddToPlaylist = { [weak self] songs, playlist in
            await self?.add(songs, to: playlist)
        }
        library.cloudRemoveFromPlaylist = { [weak self] songs, playlist in
            await self?.remove(songs, from: playlist)
        }
        library.cloudToggleFollow = { [weak self] artist in
            await self?.toggleFollow(artist)
        }
        library.cloudToggleFavoritePlaylist = { [weak self] playlist in
            await self?.toggleFavorite(playlist)
        }
        library.cloudDeletePlaylist = { [weak self] playlist in
            await self?.deletePlaylist(playlist)
        }
    }

    var isLoggedIn: Bool { user != nil && !(user?.token.isEmpty ?? true) }
    var displayName: String { user?.nickname ?? "Kugou account" }

    init() {
        user = SessionStore.user
        device = SessionStore.device
    }

    /// Registers the device, then loads the account library if signed in.
    ///
    /// Runs once per launch. A failure here (usually "sidecar not running") is
    /// recorded rather than thrown, so the shell still opens and can explain itself.
    func bootstrap() async {
        do {
            device = try await client.registerDevice()
            apiReachable = true
            lastError = nil
            if isLoggedIn {
                library?.setCurrentUser(user?.userID)
                await refreshAccountLibrary()
            }
        } catch {
            apiReachable = false
            lastError = error.localizedDescription
        }
    }

    /// Signs out: stops playback, clears the queue, and swaps the library to the
    /// signed-out bucket. The device fingerprint survives, so re-login does not
    /// re-register.
    func logout() {
        SessionStore.clearUser()
        user = nil
        player?.setUser(nil)
        player?.resetQueue()
        library?.setCurrentUser(nil)
        library?.clearAccountLibrary()
    }

    func apply(_ session: UserSession) {
        // Keep the persisted session and the in-memory auth state in lockstep.
        // Playback and APIClient must see the same credentials immediately
        // after QR/phone/password login succeeds.
        SessionStore.user = session
        user = SessionStore.user ?? session
        lastError = nil
        player?.setUser(session.userID)
        library?.setCurrentUser(session.userID)
        Task { await refreshAccountLibrary() }
    }

    /// The authoritative pull of the account library.
    ///
    /// Called on launch/login and by the manual Refresh action — never on a timer.
    /// Cloud state wins over local caches for playlists / albums / artists, which
    /// is why the whole snapshot is applied at once.
    func refreshAccountLibrary() async {
        guard isLoggedIn, let library else { return }
        library.isRefreshingAccount = true
        do {
            let snapshot = try await client.userLibrary()
            // Apply after the current SwiftUI update so Queue rows are not
            // destroyed mid-Observation (swift_release UAF).
            await Task.yield()
            library.applyAccountLibrary(snapshot)
            if let liked = snapshot.likedPlaylist {
                do {
                    let songs = try await client.songs(in: liked)
                    await Task.yield()
                    library.setAccountLikedSongs(songs)
                } catch {
                    library.accountError = error.localizedDescription
                }
            }
        } catch {
            library.accountError = error.localizedDescription
            library.hasAccountLibrary = false
        }
        library.isRefreshingAccount = false
    }

    func toggleLike(_ song: Song) async {
        await toggleLike([song])
    }

    /// Like / unlike a batch. Local state flips optimistically first; the cloud
    /// gets one joined add for the newly liked and one joined remove for the
    /// unliked. Songs without a cloud hash / file id stay local-only, mirroring
    /// the single-song behaviour.
    func toggleLike(_ songs: [Song]) async {
        guard let library, !songs.isEmpty else { return }
        let toAdd = songs.filter { !library.isLiked($0) }
        let toRemove = songs.filter { library.isLiked($0) }
        for song in songs { library.toggleLike(song) }

        guard let listID = library.accountLikedPlaylist?.listID else { return }
        do {
            if !toRemove.isEmpty {
                let removable = toRemove.compactMap(\.fileid)
                if !removable.isEmpty {
                    try await client.removeTracks(fileIDs: removable, fromListID: listID)
                }
            }
            if !toAdd.isEmpty {
                try await client.add(songs: toAdd, toListID: listID)
            }
            library.accountError = nil
        } catch {
            // The optimistic flip never reached the account: put the local state
            // back so the hearts do not lie until the next successful refresh.
            for song in songs { library.toggleLike(song) }
            library.accountError = error.localizedDescription
            return
        }

        // Best-effort resync of the cloud liked list. The write already
        // succeeded, so a failure here must not roll the local state back, and
        // the read must not undo `toAdd` / `toRemove` if the server lags.
        if let liked = library.accountLikedPlaylist {
            do {
                let refreshed = try await client.songs(in: liked)
                library.setAccountLikedSongs(refreshed, keeping: toAdd, removing: toRemove)
            } catch {
                // Keep the optimistic state.
            }
        }
    }

    func add(_ song: Song, to playlist: Playlist) async {
        await add([song], to: playlist)
    }

    /// Adds to a playlist: a cloud call for account playlists, a local insert
    /// otherwise. Only the cloud branch refreshes, because only it can have
    /// changed server-side.
    func add(_ songs: [Song], to playlist: Playlist) async {
        guard let library, !songs.isEmpty else { return }
        if let listID = playlist.listID, playlist.isAccount {
            do {
                try await client.add(songs: songs, toListID: listID)
                await refreshAccountLibrary()
                library.accountError = nil
                library.accountActionMessage = songs.count == 1
                    ? "Added “\(songs[0].title)” to \(playlist.name)."
                    : "Added \(songs.count) songs to \(playlist.name)."
            } catch {
                library.accountError = error.localizedDescription
                library.accountActionMessage = error.localizedDescription
            }
        } else {
            for song in songs { library.add(song, to: playlist) }
        }
    }

    /// Remove tracks from a playlist: one joined cloud delete, or local drops.
    ///
    /// The cloud path needs each song's `fileid` to address the right row, so
    /// anything missing one simply cannot be removed.
    func remove(_ songs: [Song], from playlist: Playlist) async {
        guard let library, !songs.isEmpty else { return }
        if let listID = playlist.listID, playlist.isAccount {
            let fileIDs = songs.compactMap(\.fileid)
            guard !fileIDs.isEmpty else {
                library.accountError = "These songs cannot be removed (missing ids)."
                return
            }
            do {
                try await client.removeTracks(fileIDs: fileIDs, fromListID: listID)
                await refreshAccountLibrary()
                library.accountError = nil
            } catch {
                library.accountError = error.localizedDescription
                library.accountActionMessage = error.localizedDescription
            }
        } else {
            for song in songs { library.remove(song, from: playlist) }
        }
    }

    /// Delete a playlist (cloud `/playlist/del`, or the local copy).
    func deletePlaylist(_ playlist: Playlist) async {
        guard let library else { return }
        if let listID = playlist.listID, playlist.isAccount {
            do {
                try await client.deletePlaylist(listID: listID)
                await refreshAccountLibrary()
                library.accountError = nil
                library.accountActionMessage = "Deleted “\(playlist.name)”."
            } catch {
                library.accountError = error.localizedDescription
                library.accountActionMessage = error.localizedDescription
            }
        } else {
            library.deletePlaylist(id: playlist.id)
        }
    }

    /// Follow / unfollow an artist. State lives in the account library, so the
    /// button reflects `accountArtists` and this just flips it in the cloud.
    func toggleFollow(_ artist: Artist) async {
        guard let library else { return }
        let singerID = artist.singerID ?? artist.id
        guard !singerID.isEmpty else { return }
        let wasFollowing = library.isFollowing(artist)
        do {
            if wasFollowing {
                try await client.unfollow(artistID: singerID)
            } else {
                try await client.follow(artistID: singerID)
            }
            library.setArtistFollowed(artist, followed: !wasFollowing)
            library.accountError = nil
        } catch {
            library.accountError = error.localizedDescription
            library.accountActionMessage = error.localizedDescription
        }
    }

    /// Collect / uncollect a browsed playlist. Collecting is `/playlist/add`
    /// with `type: 1`; uncollecting deletes the collected copy by its listid.
    ///
    /// The collected/not-collected decision is derived from the account library
    /// (never stored locally), which is why uncollecting also unpins: the pin
    /// only ever referred to that cloud copy.
    func toggleFavorite(_ playlist: Playlist) async {
        guard let library else { return }
        if let collected = library.collectedPlaylist(matching: playlist) {
            guard let listID = collected.listID else {
                library.accountError = "This playlist cannot be removed (missing list id)."
                return
            }
            do {
                try await client.deletePlaylist(listID: listID)
                library.unpin(collected)
                library.accountError = nil
                await refreshAccountLibrary()
            } catch {
                library.accountError = error.localizedDescription
                library.accountActionMessage = error.localizedDescription
            }
            return
        }
        let gid = playlist.globalCollectionID ?? playlist.id
        guard !gid.isEmpty else { return }
        do {
            try await client.collectPlaylist(
                name: playlist.name,
                listCreateUserID: user?.userID ?? "",
                globalCollectionID: gid
            )
            library.accountError = nil
            await refreshAccountLibrary()
        } catch {
            library.accountError = error.localizedDescription
            library.accountActionMessage = error.localizedDescription
        }
    }
}
