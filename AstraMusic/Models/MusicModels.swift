import Foundation

/// A playable track.
///
/// Identity is `id`, which should always be the canonical 128 hash — see
/// `canonicalID(hash:fileHash:)` for why. `hash` and `fileHash` are kept
/// separately because playback resolution needs them (they feed
/// `/privilege/lite` and `/song/url`) and because Kugou returns different
/// hashes per row type.
struct Song: Identifiable, Hashable, Codable {
    let id: String
    var title: String
    var artistName: String
    var albumTitle: String
    var duration: TimeInterval
    var artworkSymbol: String
    /// Kugou `Image` / `sizable_cover` template, often containing `{size}`.
    var artworkTemplate: String? = nil
    var hash: String?
    /// Standard 128 hash from search `FileHash`. Playback prefers this after privilege/lite.
    var fileHash: String? = nil
    /// Playlist-row id for `/playlist/tracks/del`. Not always present.
    var fileid: String? = nil
    /// Resolved stream URL for playback. Not persisted — re-resolved on every play.
    var playbackURL: URL?

    var durationLabel: String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `playbackURL` is intentionally absent: persisted songs must never carry a
    /// CDN URL, since those expire and are re-resolved per play. Omitting it here
    /// keeps it out of `library.json` automatically.
    enum CodingKeys: String, CodingKey {
        case id, title, artistName, albumTitle, duration, artworkSymbol, artworkTemplate, hash, fileHash, fileid
    }
}

extension Song {
    /// Canonical identity for a track. Search / playlist rows carry an HQ hash in
    /// `hash` (`HQFileHash ?? SQFileHash ?? FileHash`), while album / artist rows
    /// carry the base hash, so keying identity on `hash` split the same song into
    /// two ids. The standard 128 hash is the value every endpoint agrees on.
    static func canonicalID(hash: String?, fileHash: String?) -> String {
        for candidate in [fileHash, hash] {
            if let candidate, !candidate.isEmpty { return candidate.lowercased() }
        }
        return ""
    }

    /// A copy whose `id` is the canonical 128-hash identity. Playback keeps using
    /// `hash` / `fileHash`, so this rewrites identity only.
    func normalized() -> Song {
        let canonical = Self.canonicalID(hash: hash, fileHash: fileHash)
        guard !canonical.isEmpty, canonical != id else { return self }
        return Song(
            id: canonical,
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            artworkSymbol: artworkSymbol,
            artworkTemplate: artworkTemplate,
            hash: hash,
            fileHash: fileHash,
            fileid: fileid,
            playbackURL: playbackURL
        )
    }
}

/// An album.
///
/// Kugou has no dedicated album in the user library: an "album" that the account
/// owns is really a playlist row whose `authors` field is set, which is why
/// `playlistID` exists and is what actually opens it.
struct Album: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var title: String
    var artistName: String
    var artworkSymbol: String
    var artworkTemplate: String? = nil
    var year: Int?
    /// Account collected albums are playlist rows; open via `/playlist/track/all`.
    var playlistID: String? = nil
    var count: Int? = nil

    init(
        id: String,
        title: String,
        artistName: String,
        artworkSymbol: String,
        artworkTemplate: String? = nil,
        year: Int? = nil,
        playlistID: String? = nil,
        count: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.artistName = artistName
        self.artworkSymbol = artworkSymbol
        self.artworkTemplate = artworkTemplate
        self.year = year
        self.playlistID = playlistID
        self.count = count
    }

    /// Synthetic identity for rows that arrive without a usable id.
    static func id(title: String, artistName: String) -> String {
        "\(title)|\(artistName)"
    }
}

/// An artist.
///
/// `id` is whatever the row was parsed from (search result id or account-library
/// id); `singerID` preserves Kugou's own singer id when the payload includes it.
struct Artist: Identifiable, Hashable, Codable, Sendable {
    let id: String
    var name: String
    var artworkSymbol: String
    var artworkTemplate: String? = nil
    var singerID: String? = nil

    init(id: String, name: String, artworkSymbol: String, artworkTemplate: String? = nil, singerID: String? = nil) {
        self.id = id
        self.name = name
        self.artworkSymbol = artworkSymbol
        self.artworkTemplate = artworkTemplate
        self.singerID = singerID
    }
}

/// A playlist, in any of the several shapes Kugou uses for one.
///
/// The two id fields are the thing to get right: `listID` is the *mutation* id
/// (`/playlist/tracks/add`, `/playlist/tracks/del`, `/playlist/del`) while
/// `trackFetchID` is the *read* id (`/playlist/track/all`). Handing a `listid` to
/// the read endpoint 502s.
struct Playlist: Identifiable, Hashable, Codable, Sendable {
    /// Where this playlist came from, which decides whether it is writable and
    /// whether it survives sign-out.
    enum Kind: String, Codable, Hashable {
        /// Created on this Mac; stored in `library.json` and wiped on sign-out.
        case local
        /// Cloud playlist the signed-in user created.
        case owned
        /// Cloud playlist the user saved from someone else — removable, not editable.
        case collected
        /// The account's "Liked Songs" row. Not deletable.
        case liked
        /// Home / chart curation. Read-only and not part of the account.
        case featured
        /// An account library album, opened through the playlist endpoints.
        case collectedAlbum
    }

    let id: String
    var name: String
    var artworkSymbol: String
    var artworkTemplate: String? = nil
    var intro: String? = nil
    var songIDs: [String]
    var kind: Kind
    /// Mutation id for `/playlist/tracks/add` and `/playlist/del`. Never use as `/playlist/track/all` id.
    var listID: String? = nil
    var globalCollectionID: String? = nil
    var count: Int? = nil
    var listCreateUserid: String? = nil
    var listCreateListid: String? = nil

    /// Read id for `/playlist/track/all`: account rows carry a global collection
    /// id (gid) and expect that instead of the local id.
    var trackFetchID: String { globalCollectionID ?? id }
    /// True for lists backed by the account — i.e. everything except an
    /// on-this-Mac list and a Home curation.
    var isAccount: Bool { kind != .local && kind != .featured }

    /// Shared grid/list caption: "N songs" when known, else the creator hint.
    var subtitle: String {
        if let count { return "\(count) songs" }
        return intro ?? "Playlist"
    }

    init(
        id: String,
        name: String,
        artworkSymbol: String,
        artworkTemplate: String? = nil,
        intro: String? = nil,
        songIDs: [String],
        kind: Kind = .local,
        listID: String? = nil,
        globalCollectionID: String? = nil,
        count: Int? = nil,
        listCreateUserid: String? = nil,
        listCreateListid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.artworkSymbol = artworkSymbol
        self.artworkTemplate = artworkTemplate
        self.intro = intro
        self.songIDs = songIDs
        self.kind = kind
        self.listID = listID
        self.globalCollectionID = globalCollectionID
        self.count = count
        self.listCreateUserid = listCreateUserid
        self.listCreateListid = listCreateListid
    }

    enum CodingKeys: String, CodingKey {
        case id, name, artworkSymbol, artworkTemplate, intro, songIDs
        case kind, listID, globalCollectionID, count, listCreateUserid, listCreateListid
    }

    /// Decoded leniently on purpose: `library.json` is written by older builds of
    /// this app, so every field except `id` / `name` has a fallback.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        artworkSymbol = try container.decodeIfPresent(String.self, forKey: .artworkSymbol) ?? "music.note.list"
        artworkTemplate = try container.decodeIfPresent(String.self, forKey: .artworkTemplate)
        intro = try container.decodeIfPresent(String.self, forKey: .intro)
        songIDs = try container.decodeIfPresent([String].self, forKey: .songIDs) ?? []
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .local
        listID = try container.decodeIfPresent(String.self, forKey: .listID)
        globalCollectionID = try container.decodeIfPresent(String.self, forKey: .globalCollectionID)
        count = try container.decodeIfPresent(Int.self, forKey: .count)
        listCreateUserid = try container.decodeIfPresent(String.self, forKey: .listCreateUserid)
        listCreateListid = try container.decodeIfPresent(String.self, forKey: .listCreateListid)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(artworkSymbol, forKey: .artworkSymbol)
        try container.encodeIfPresent(artworkTemplate, forKey: .artworkTemplate)
        try container.encodeIfPresent(intro, forKey: .intro)
        try container.encode(songIDs, forKey: .songIDs)
        // `.local` is the decode-time default, so it is omitted to keep
        // `library.json` lean and stable across builds.
        if kind != .local {
            try container.encode(kind, forKey: .kind)
        }
        try container.encodeIfPresent(listID, forKey: .listID)
        try container.encodeIfPresent(globalCollectionID, forKey: .globalCollectionID)
        try container.encodeIfPresent(count, forKey: .count)
        try container.encodeIfPresent(listCreateUserid, forKey: .listCreateUserid)
        try container.encodeIfPresent(listCreateListid, forKey: .listCreateListid)
    }
}

/// One snapshot of the signed-in account's library.
///
/// Rebuilt wholesale on every refresh and never persisted — the account is
/// authoritative, so there is nothing to save. Signs out by being discarded.
struct UserLibrary: Sendable {
    var ownedPlaylists: [Playlist] = []
    var collectedPlaylists: [Playlist] = []
    var collectedAlbums: [Album] = []
    var followedArtists: [Artist] = []
    var likedPlaylist: Playlist? = nil
}

/// One displayed lyric line.
///
/// `id` is the line index (stable for `ForEach`), and `time` is the line's start
/// offset in seconds — KRC word-level timings are flattened away by
/// `LyricsParser` before they reach the UI.
struct LyricLine: Identifiable, Hashable, Codable {
    let id: Int
    var time: TimeInterval
    var text: String

    var timeLabel: String {
        let total = Int(time.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
