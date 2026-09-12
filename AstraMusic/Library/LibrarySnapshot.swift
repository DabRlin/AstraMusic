import Foundation

/// The on-disk format of `library.json`.
///
/// Only "on this Mac" data lives here: local playlists, and the per-user buckets
/// for likes, recents, and pins. Account playlists / albums / artists are
/// deliberately absent — they are rebuilt from the cloud on every refresh.
///
/// **Do not add a non-optional field without a default.** `load()` treats a
/// decode failure as "start over", so a required field the existing file lacks
/// would silently wipe the user's library. New fields must be optional so old
/// files keep decoding.
struct LibrarySnapshot: Codable, Equatable {
    /// Legacy account-agnostic likes, folded into `likedSongIDsByUser` on load.
    var likedSongIDs: [String]
    var likedSongIDsByUser: [String: [String]]?
    var recentSongIDs: [String]
    var playlists: [Playlist]
    var rememberedSongs: [Song]?
    var recentSongIDsByUser: [String: [String]]?
    var pinnedPlaylistIDsByUser: [String: [String]]?
}
