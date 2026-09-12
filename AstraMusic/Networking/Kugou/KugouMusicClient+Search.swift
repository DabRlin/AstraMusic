import Foundation

/// Paged search and the `SearchSong` / `SearchResult` row parsers it shares
/// with the recommendation and library surfaces.
extension KugouMusicClient {

    /// Paged search. Song searches fill `lists`; every other kind is mapped
    /// through `parseSearchResult`. `total` is 0 when the server omits it.
    func search(keywords: String, type: SearchType, page: Int = 1, pageSize: Int = 30) async throws -> SearchPage {
        let json = try await api.get("/search", query: [
            "keywords": keywords,
            "page": String(page),
            "pagesize": String(pageSize),
            "type": type.rawValue,
        ])
        let lists = json.data["lists"].array
        let total = json.data.int("total") ?? json.int("total") ?? 0
        if type == .song {
            return SearchPage(songs: lists.compactMap(Self.parseSearchSong), total: total, page: page, pageSize: pageSize)
        }
        let results = lists.compactMap { Self.parseSearchResult($0, type: type) }
        return SearchPage(results: results, total: total, page: page, pageSize: pageSize)
    }

    /// Parses a search / recommendation / playlist row into a `SearchSong`.
    ///
    /// The HQ hash becomes the row's `hash` (`HQFileHash ?? SQFileHash ??
    /// FileHash`) while `fileHash` keeps the standard 128 hash — `canonicalID`
    /// reconciles the two. Field names differ per endpoint, hence the probes, and
    /// durations arrive in ms on some endpoints, hence the `> 1000` heuristic.
    static func parseSearchSong(_ json: AnyJSON) -> SearchSong? {
        let hash = json.string("HQFileHash")
            ?? json.string("SQFileHash")
            ?? json.string("FileHash")
            ?? json.string("hash")
        guard let hash, !hash.isEmpty else { return nil }
        let fileHash = json.string("FileHash") ?? json.string("hash")
        let title = json.string("OriSongName")
            ?? json.string("SongName")
            ?? json.string("ori_audio_name")
            ?? json.string("songname")
            ?? json.string("audio_name")
            ?? json.string("name")
            ?? "Unknown"
        let artist = json.string("SingerName")
            ?? json.string("author_name")
            ?? json.string("author")
            ?? "Unknown"
        let album = json.string("AlbumName")
            ?? json.string("album_name")
            ?? json["albuminfo"].string("name")
            ?? ""
        let durationMs = json.double("Duration")
            ?? json.double("duration")
            ?? json.double("time_length")
            ?? json.double("timelen")
            ?? json.double("timelength")
            ?? 0
        let duration = durationMs > 1000 ? durationMs / 1000 : durationMs
        let artwork = json.string("Image")
            ?? json.string("album_sizable_cover")
            ?? json.string("sizable_cover")
            ?? json.string("cover")
            ?? json["trans_param"].string("union_cover")
        let fileid = json.string("fileid")
            ?? json.int("fileid").map(String.init)
            ?? json.string("file_id")
        return SearchSong(
            hash: hash,
            fileHash: fileHash,
            fileid: fileid,
            title: Self.displayTitle(title, artist: artist),
            artistName: artist == "Unknown" ? Self.artistFromCombined(title) : artist,
            albumTitle: album,
            duration: duration,
            artworkTemplate: artwork
        )
    }

    /// Maps a non-song search row to a `SearchResult`.
    ///
    /// Each kind has its own field spellings and id name, and the result id is
    /// prefixed (`album-`, `author-`, `playlist-`) so rows of different kinds can
    /// share one list without colliding.
    private static func parseSearchResult(_ json: AnyJSON, type: SearchType) -> SearchResult? {
        switch type {
        case .album:
            let id = json.string("albumid") ?? json.string("AlbumID") ?? json.string("album_id") ?? json.int("albumid").map(String.init) ?? ""
            let title = json.string("albumname") ?? json.string("AlbumName") ?? json.string("album_name") ?? ""
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let artist = json.string("author_name") ?? json.string("AuthorName") ?? json["singers"].array.first?.string("name") ?? "Album"
            let cover = json.string("img") ?? json.string("Img") ?? json.string("sizable_cover") ?? json.string("album_sizable_cover")
            let album = Album(id: id, title: title, artistName: artist, artworkSymbol: "square.stack.fill", artworkTemplate: cover)
            return SearchResult(id: "album-\(id)", type: type, subtitle: artist, song: nil, album: album, artist: nil, playlist: nil)
        case .author:
            // `/v1/search/author` returns PascalCase `AuthorId` (other search
            // types use lowercase `albumid` / `specialid`), so check it first.
            let id = json.firstString(["AuthorId", "authorid", "AuthorID", "singerid", "SingerID", "id"]) ?? ""
            let title = json.firstString(["authorname", "AuthorName", "nickname", "name"]) ?? ""
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let cover = json.firstString(["avatar", "Avatar", "pic", "Pic"])
            let artist = Artist(id: id, name: title, artworkSymbol: "person.fill", artworkTemplate: cover, singerID: id)
            return SearchResult(id: "author-\(id)", type: type, subtitle: "Artist", song: nil, album: nil, artist: artist, playlist: nil)
        case .special:
            // `/playlist/track/all` needs the collection gid (the web client
            // uses `playlist.gid`), not the numeric specialid.
            let id = json.string("gid") ?? json.string("global_collection_id") ?? json.string("specialid") ?? json.string("SpecialID") ?? json.int("specialid").map(String.init) ?? ""
            let title = json.string("specialname") ?? json.string("SpecialName") ?? json.string("name") ?? ""
            guard !id.isEmpty, !title.isEmpty else { return nil }
            let creator = json.string("nickname") ?? json.string("NickName") ?? json.string("username") ?? "Playlist"
            let cover = json.string("img") ?? json.string("Img") ?? json.string("sizable_cover") ?? json.string("flexible_cover")
            let playlist = Playlist(id: id, name: title, artworkSymbol: "music.note.list", artworkTemplate: cover, songIDs: [], kind: .featured, globalCollectionID: id)
            return SearchResult(id: "playlist-\(id)", type: type, subtitle: creator, song: nil, album: nil, artist: nil, playlist: playlist)
        case .song:
            guard let song = parseSearchSong(json) else { return nil }
            return SearchResult(id: song.id, type: type, subtitle: song.artistName, song: song, album: nil, artist: nil, playlist: nil)
        }
    }

    /// Playlist rows often look like `"Artist - Title"`.
    private static func displayTitle(_ raw: String, artist: String) -> String {
        let parts = raw.split(separator: " - ", maxSplits: 1).map(String.init)
        if parts.count == 2, artist == "Unknown" || parts[0] == artist {
            return parts[1]
        }
        return raw
    }

    /// Recovers the artist from a combined `"Artist - Title"` row when no
    /// dedicated artist field is present.
    private static func artistFromCombined(_ raw: String) -> String {
        let parts = raw.split(separator: " - ", maxSplits: 1).map(String.init)
        return parts.count == 2 ? parts[0] : "Unknown"
    }
}
