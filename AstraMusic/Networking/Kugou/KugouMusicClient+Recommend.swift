import Foundation

/// Home discovery reads (`/everyday/recommend`, `/top/playlist`) plus the song,
/// album, and artist row parsers they share with the library surface.
extension KugouMusicClient {

    /// Home "For you" feed. Rows that cannot be parsed are skipped rather than
    /// failing the whole request.
    func dailyRecommend() async throws -> [Song] {
        let json = try await api.get("/everyday/recommend")
        return Self.songList(in: json).compactMap(Self.parseRecommendSong)
    }

    /// Chart / curated playlists for Home.
    ///
    /// Returned as `.featured`: they belong to nobody's account, are read-only,
    /// and are addressed by `global_collection_id` — which is also used as the
    /// id, so `trackFetchID` resolves without a separate gid field.
    func recommendedPlaylists() async throws -> [Playlist] {
        let json = try await api.get("/top/playlist", query: ["category_id": "0"])
        let list = json.data["special_list"].array
        return list.compactMap { item in
            let id = item.string("global_collection_id") ?? item.string("specialid") ?? ""
            let name = item.string("specialname") ?? item.string("name") ?? ""
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return Playlist(
                id: id,
                name: name,
                artworkSymbol: "music.note.list",
                artworkTemplate: item.string("flexible_cover")
                    ?? item.string("imgurl")
                    ?? item.string("sizable_cover"),
                intro: item.string("intro"),
                songIDs: [],
                kind: .featured,
                globalCollectionID: id
            )
        }
    }

    /// Home / Radio payloads use `hash`, `ori_audio_name`, `sizable_cover`, `author_name`.
    private static func parseRecommendSong(_ json: AnyJSON) -> Song? {
        parseSearchSong(json)?.asSong()
    }

    /// Playlist rows reuse the flat search shape.
    static func parsePlaylistSong(_ json: AnyJSON) -> Song? {
        parseSearchSong(json)?.asSong()
    }

    /// `/everyday/recommend` puts its rows under `song_list`, or directly in `data`.
    private static func songList(in json: AnyJSON) -> [AnyJSON] {
        let nested = json.data["song_list"].array
        if !nested.isEmpty { return nested }
        let top = json["song_list"].array
        if !top.isEmpty { return top }
        return json.data.array
    }

    /// `/album/songs` rows nest their data as `audio_info` / `base` / `album_info`.
    /// Falls back to the flat search shape when the nested hash is missing.
    static func parseAlbumSong(_ json: AnyJSON) -> Song? {
        let audio = json["audio_info"]
        let base = json["base"]
        let album = json["album_info"]
        let hash = audio.string("hash") ?? audio.string("hash_128") ?? base.string("hash") ?? json.string("hash")
        guard let hash, !hash.isEmpty else { return parseSearchSong(json)?.asSong() }
        let fileHash = audio.string("hash") ?? audio.string("hash_128") ?? hash
        let durationMs = audio.double("duration") ?? audio.double("timelength") ?? base.double("duration") ?? json.double("duration") ?? json.double("timelength") ?? 0
        return Song(
            id: Song.canonicalID(hash: hash, fileHash: fileHash),
            title: base.string("audio_name") ?? base.string("songname") ?? json.string("audio_name") ?? json.string("songname") ?? "Unknown",
            artistName: base.string("author_name") ?? base.string("singername") ?? json.string("author_name") ?? json.string("singername") ?? "Unknown",
            albumTitle: album.string("album_name") ?? json.string("album_name") ?? "",
            duration: durationMs > 1000 ? durationMs / 1000 : durationMs,
            artworkSymbol: "music.note",
            artworkTemplate: json["trans_param"].string("union_cover") ?? album.string("sizable_cover") ?? json.string("sizable_cover"),
            hash: hash,
            fileHash: fileHash,
            fileid: json.string("fileid") ?? json.int("fileid").map(String.init)
        )
    }

    /// `/artist/audios` rows are flat, and the hash doubles as the file hash.
    static func parseArtistSong(_ json: AnyJSON) -> Song? {
        let hash = json.string("hash")
        guard let hash, !hash.isEmpty else { return parseSearchSong(json)?.asSong() }
        let durationMs = json.double("timelength") ?? json.double("duration") ?? 0
        return Song(
            id: Song.canonicalID(hash: hash, fileHash: hash),
            title: json.string("audio_name") ?? json.string("songname") ?? "Unknown",
            artistName: json.string("author_name") ?? "Unknown",
            albumTitle: json.string("album_name") ?? "",
            duration: durationMs > 1000 ? durationMs / 1000 : durationMs,
            artworkSymbol: "music.note",
            artworkTemplate: json["trans_param"].string("union_cover") ?? json.string("sizable_avatar"),
            hash: hash,
            fileHash: hash
        )
    }

    /// `/artist/albums` rows: `album_id` / `album_name` / `sizable_cover` /
    /// `authors` / `publish_date`.
    static func parseArtistAlbum(_ json: AnyJSON, artist: Artist) -> Album? {
        let id = json.string("album_id") ?? ""
        let title = json.string("album_name") ?? ""
        guard !id.isEmpty, !title.isEmpty else { return nil }
        let artistName = json.string("author_name")
            ?? json["authors"].array.first?.string("author_name")
            ?? artist.name
        let cover = json.string("sizable_cover") ?? json.string("cover")
        let year = json.string("publish_date").flatMap { Int($0.prefix(4)) }
        return Album(
            id: id,
            title: title,
            artistName: artistName,
            artworkSymbol: "square.stack.fill",
            artworkTemplate: cover,
            year: year
        )
    }
}
