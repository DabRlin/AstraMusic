import Foundation
import Observation

/// Everything "on this Mac" plus a cache of the signed-in account's library.
///
/// Two layers, with different lifetimes:
///
/// - **Local** (`likedSongIDs`, `recentSongIDs`, `pinnedPlaylistIDs`,
///   `playlists`) — persisted to `library.json`, bucketed per user id. The
///   un-suffixed properties are not the storage; they are the *current user's*
///   mirror of the `…ByUser` dictionaries. `setCurrentUser` flushes the mirror
///   into the outgoing user's bucket and loads the incoming one; `save()` writes
///   the mirror back into its bucket. Guests get empty mirrors.
/// - **Account** (`account…`) — in memory only, rebuilt wholesale by
///   `applyAccountLibrary`. Blank on cold launch until a refresh lands, which is
///   the accepted v1 trade-off.
@Observable
@MainActor
final class LibraryStore {
    static let recentLimit = 50

    /// Remote songs (search / play) remembered so likes, recents, and playlists keep covers.
    var rememberedSongs: [String: Song] = [:]
    var likedSongIDs: [String] = []
    var likedSongIDsByUser: [String: [String]] = [:]
    var recentSongIDs: [String] = []
    var recentSongIDsByUser: [String: [String]] = [:]
    var pinnedPlaylistIDs: [String] = []
    var pinnedPlaylistIDsByUser: [String: [String]] = [:]
    var currentUserID: String?
    /// Local playlists only. Never write account lists into library.json.
    var playlists: [Playlist] = []

    var accountOwnedPlaylists: [Playlist] = []
    var accountCollectedPlaylists: [Playlist] = []
    var accountAlbums: [Album] = []
    var accountArtists: [Artist] = []
    var accountLikedPlaylist: Playlist? = nil
    var accountLikedSongs: [Song] = []
    /// Last account failure / success, surfaced by the library UI.
    var accountError: String?
    var accountActionMessage: String?
    var isRefreshingAccount = false
    /// False until a successful refresh, which is what distinguishes "not loaded
    /// yet" from "genuinely empty account".
    var hasAccountLibrary = false

    @ObservationIgnored
    let fileURL: URL
    @ObservationIgnored
    let persistToDisk: Bool
    /// Cloud like / add, installed by AuthStore. Rows must not hold AuthStore.
    @ObservationIgnored
    var cloudToggleLike: (([Song]) async -> Void)?
    @ObservationIgnored
    var cloudAddToPlaylist: (([Song], Playlist) async -> Void)?
    @ObservationIgnored
    var cloudRemoveFromPlaylist: (([Song], Playlist) async -> Void)?
    /// Cloud artist follow / playlist collect, also installed by AuthStore.
    @ObservationIgnored
    var cloudToggleFollow: ((Artist) async -> Void)?
    @ObservationIgnored
    var cloudToggleFavoritePlaylist: ((Playlist) async -> Void)?
    /// Cloud playlist delete, installed by AuthStore.
    @ObservationIgnored
    var cloudDeletePlaylist: ((Playlist) async -> Void)?
    /// Account-agnostic lists from a pre-buckets file, held until `setCurrentUser`
    /// can attribute them to an account. Cleared once migrated.
    @ObservationIgnored
    var legacyGlobalRecents: [String]?
    @ObservationIgnored
    var legacyGlobalLikes: [String]?

    /// `persistToDisk: false` is for previews: same behaviour, no writes.
    init(persistToDisk: Bool = true, fileURL: URL? = nil) {
        self.persistToDisk = persistToDisk
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if persistToDisk {
            load()
        } else {
            seed()
        }
    }
}
