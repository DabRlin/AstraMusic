import Foundation

/// Account-library surface: playlist / album / artist reads, the account
/// snapshot, follow and collect, playlist mutations, and their row parsers.
extension KugouMusicClient {

    /// Reads a playlist's tracks through `/playlist/track/all`, 300 per page.
    /// This is the read path — mutations use `listID` instead.
    func songs(in playlist: Playlist) async throws -> [Song] {
        try await pagedSongs(
            pageSize: 300,
            fetch: { page, pageSize in
                let json = try await api.get("/playlist/track/all", query: [
                    "id": playlist.trackFetchID,
                    "pagesize": String(pageSize),
                    "page": String(page),
                ])
                return Self.playlistTrackRows(in: json).compactMap(Self.parsePlaylistSong)
            }
        )
    }

    /// Builds the account snapshot from the playlist rows plus `/user/follow`.
    ///
    /// The two requests run concurrently and the follow list is optional: a
    /// failure there still yields playlists, since losing a few artists should
    /// not take down the whole account library.
    func userLibrary() async throws -> UserLibrary {
        async let playlistsJSON = fetchAllPlaylistPages()
        async let followJSON = api.get("/user/follow")
        let playlists = try await playlistsJSON
        let follows = try? await followJSON
        return Self.parseUserLibrary(rows: playlists, follows: follows)
    }

    /// Albums that came from the account library are really playlist rows, so
    /// they open through the playlist endpoint; the real `/album/songs` is only
    /// used when there is no `playlistID`.
    func songs(in album: Album) async throws -> [Song] {
        if let playlistID = album.playlistID, !playlistID.isEmpty {
            return try await songs(in: Playlist(
                id: playlistID,
                name: album.title,
                artworkSymbol: album.artworkSymbol,
                artworkTemplate: album.artworkTemplate,
                songIDs: [],
                kind: .collectedAlbum,
                globalCollectionID: playlistID
            ))
        }
        // `/album/songs` rejects pagesize > 50 upstream (verified: 50 ok,
        // 60+ → 502), so the album page size stays at 50.
        return try await pagedSongs(
            pageSize: 50,
            fetch: { page, pageSize in
                let json = try await api.get("/album/songs", query: [
                    "id": album.id,
                    "pagesize": String(pageSize),
                    "page": String(page),
                ])
                let rows = Self.albumSongRows(in: json)
                return rows.compactMap(Self.parseAlbumSong)
            }
        )
    }

    /// An artist's hot tracks (single page of 50).
    func songs(by artist: Artist) async throws -> [Song] {
        let singerID = artist.singerID ?? artist.id
        let json = try await api.get("/artist/audios", query: [
            "id": singerID,
            "pagesize": "50",
            "page": "1",
            "sort": "hot",
        ])
        let rows = json.data.array.isEmpty ? json.array : json.data.array
        return rows.compactMap(Self.parseArtistSong)
    }

    /// An artist's albums (single page of 50).
    func albums(by artist: Artist) async throws -> [Album] {
        let singerID = artist.singerID ?? artist.id
        let json = try await api.get("/artist/albums", query: [
            "id": singerID,
            "pagesize": "50",
            "page": "1",
            "sort": "hot",
        ])
        let rows = json.data.array.isEmpty ? json.array : json.data.array
        return rows.compactMap { Self.parseArtistAlbum($0, artist: artist) }
    }

    /// Follows an artist. Kugou answers with HTTP 200 and `status == 0` on
    /// failure, so the body must be inspected rather than the status code.
    func follow(artistID: String) async throws {
        guard !artistID.isEmpty else { throw APIError.empty }
        let json = try await api.get("/artist/follow", query: ["id": artistID])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not follow the artist.")
        }
    }

    /// Unfollows an artist; same `status == 0` failure convention as `follow`.
    func unfollow(artistID: String) async throws {
        guard !artistID.isEmpty else { throw APIError.empty }
        let json = try await api.get("/artist/unfollow", query: ["id": artistID])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not unfollow the artist.")
        }
    }

    /// `type: 1` makes `/playlist/add` collect an existing playlist instead of
    /// creating one. `list_create_gid` must be the source playlist's gid.
    ///
    /// A blank name or gid is rejected before the request; `list_create_userid`
    /// is only sent when known.
    func collectPlaylist(name: String, listCreateUserID: String, globalCollectionID: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !globalCollectionID.isEmpty else { throw APIError.empty }
        var query = [
            "name": trimmed,
            "type": "1",
            "list_create_gid": globalCollectionID,
        ]
        if !listCreateUserID.isEmpty {
            query["list_create_userid"] = listCreateUserID
        }
        let json = try await api.get("/playlist/add", query: query)
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not collect the playlist.")
        }
    }

    /// Appends one track. `/playlist/tracks/add` takes `title|hash` records, and
    /// the record list is comma-separated, so the title must not contain a comma.
    func add(song: Song, toListID listID: String) async throws {
        let hash = song.fileHash ?? song.hash ?? song.id
        guard !hash.isEmpty, !listID.isEmpty else { throw APIError.empty }
        let title = song.title.replacingOccurrences(of: ",", with: " ")
        let json = try await api.get("/playlist/tracks/add", query: [
            "listid": listID,
            "data": "\(title)|\(hash)",
        ])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not add the track.")
        }
    }

    /// Appends many tracks in a single request (comma-separated `title|hash`
    /// records). Songs with no usable hash, or synthetic `local_` ones, are
    /// dropped instead of failing the batch.
    func add(songs: [Song], toListID listID: String) async throws {
        let records = songs.compactMap { song -> String? in
            guard let hash = song.fileHash ?? song.hash, !hash.isEmpty, !hash.hasPrefix("local_") else { return nil }
            let title = song.title.replacingOccurrences(of: ",", with: " ")
            return "\(title)|\(hash)"
        }
        guard !records.isEmpty, !listID.isEmpty else { throw APIError.empty }
        let json = try await api.get("/playlist/tracks/add", query: [
            "listid": listID,
            "data": records.joined(separator: ","),
        ])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not add the tracks.")
        }
    }

    /// Removes many rows in one request, addressed by their playlist `fileid`s
    /// (not hashes). Blank ids are filtered out.
    func removeTracks(fileIDs: [String], fromListID listID: String) async throws {
        let ids = fileIDs.filter { !$0.isEmpty }
        guard !ids.isEmpty, !listID.isEmpty else { throw APIError.empty }
        let json = try await api.get("/playlist/tracks/del", query: [
            "listid": listID,
            "fileids": ids.joined(separator: ","),
        ])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not remove the tracks.")
        }
    }

    /// Removes a single playlist row by its `fileid`.
    func removeTrack(fileid: String, fromListID listID: String) async throws {
        guard !fileid.isEmpty, !listID.isEmpty else { throw APIError.empty }
        let json = try await api.get("/playlist/tracks/del", query: [
            "listid": listID,
            "fileids": fileid,
        ])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not remove the track.")
        }
    }

    /// Deletes an owned playlist. Uses the mutation id (`listid`), never the gid.
    func deletePlaylist(listID: String) async throws {
        guard !listID.isEmpty else { throw APIError.empty }
        let json = try await api.get("/playlist/del", query: ["listid": listID])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not delete the playlist.")
        }
    }

    /// Pages through `/user/playlist` to get the complete account list.
    ///
    /// The endpoint reports no total, so this stops on an empty or short page.
    /// Rows are de-duplicated by playlist gid, since the same playlist can appear
    /// on more than one page.
    private func fetchAllPlaylistPages() async throws -> [AnyJSON] {
        var rows: [AnyJSON] = []
        var seen = Set<String>()
        let pageSize = 100
        for page in 1...50 {
            let json = try await api.get("/user/playlist", query: [
                "pagesize": String(pageSize),
                "page": String(page),
                "t": String(Int(Date().timeIntervalSince1970 * 1000)),
            ])
            let batch = json.data["info"].array.isEmpty ? json.data.array : json.data["info"].array
            if batch.isEmpty { break }
            for item in batch {
                let key = item.string("listid")
                    ?? item.string("global_collection_id")
                    ?? item.string("list_create_gid")
                    ?? "\(page)-\(rows.count)"
                if seen.insert(key).inserted {
                    rows.append(item)
                }
            }
            if batch.count < pageSize { break }
        }
        return rows
    }

    /// Generic pager for track lists.
    ///
    /// Stops on an empty page, a short page, or a page that added no new ids — the
    /// last guard protects against a server that repeats the same page forever.
    /// Results are de-duplicated by canonical id.
    private func pagedSongs(
        pageSize: Int,
        fetch: (Int, Int) async throws -> [Song]
    ) async throws -> [Song] {
        var songs: [Song] = []
        var seen = Set<String>()
        for page in 1...40 {
            let batch = try await fetch(page, pageSize)
            if batch.isEmpty { break }
            let beforeCount = songs.count
            for song in batch where seen.insert(song.id).inserted {
                songs.append(song)
            }
            if songs.count == beforeCount { break }
            if batch.count < pageSize { break }
        }
        return songs
    }

    /// `/playlist/track/all` puts tracks under `songs`, sometimes `info`, and
    /// sometimes directly in `data`. Take whichever is populated.
    private static func playlistTrackRows(in json: AnyJSON) -> [AnyJSON] {
        let songs = json.data["songs"].array
        if !songs.isEmpty { return songs }
        let info = json.data["info"].array
        if !info.isEmpty { return info }
        return json.data.array
    }

    /// `/album/songs` is equally inconsistent: `songs`, `lists`, `info`, or bare.
    private static func albumSongRows(in json: AnyJSON) -> [AnyJSON] {
        let songs = json.data["songs"].array
        if !songs.isEmpty { return songs }
        let lists = json.data["lists"].array
        if !lists.isEmpty { return lists }
        let info = json.data["info"].array
        if !info.isEmpty { return info }
        return json.data.array
    }

    /// Classifies the account's playlist rows into owned / collected / liked /
    /// albums, ordered by each row's `sort` field.
    ///
    /// The liked row is also one of the user's own lists, so it is added to
    /// `owned` and then removed from it, keeping the sidebar free of a duplicate.
    /// Album rows are reshaped from `Playlist` to `Album` at this point.
    private static func parseUserLibrary(rows: [AnyJSON], follows: AnyJSON?) -> UserLibrary {
        let userID = SessionStore.user?.userID ?? ""
        let sorted = rows.sorted { (a, b) in
            (a.int("sort") ?? 0) < (b.int("sort") ?? 0)
        }

        var owned: [Playlist] = []
        var collected: [Playlist] = []
        var albums: [Album] = []
        var liked: Playlist?

        for item in sorted {
            guard let parsed = parseAccountPlaylist(item, userID: userID) else { continue }
            switch parsed.kind {
            case .liked:
                liked = parsed
                owned.insert(parsed, at: 0)
            case .owned:
                owned.append(parsed)
            case .collected:
                collected.append(parsed)
            case .collectedAlbum:
                albums.append(Album(
                    id: parsed.globalCollectionID ?? parsed.id,
                    title: parsed.name,
                    artistName: parsed.intro ?? "Album",
                    artworkSymbol: "square.stack.fill",
                    artworkTemplate: parsed.artworkTemplate,
                    playlistID: parsed.trackFetchID,
                    count: parsed.count
                ))
            default:
                collected.append(parsed)
            }
        }

        if let liked {
            owned.removeAll { $0.id == liked.id }
        }

        var library = UserLibrary(
            ownedPlaylists: owned,
            collectedPlaylists: collected,
            collectedAlbums: albums,
            likedPlaylist: liked
        )
        if let follows {
            library.followedArtists = parseFollowedArtists(follows)
        }
        return library
    }

    /// Turns one `/user/playlist` row into a `Playlist`, choosing its `Kind`.
    ///
    /// Order matters: the liked row is recognised by name, ownership by
    /// `list_create_userid`, and "album" is the fallback for rows carrying
    /// `authors` — the same test `Album` uses elsewhere.
    private static func parseAccountPlaylist(_ item: AnyJSON, userID: String) -> Playlist? {
        let listID = item.string("listid") ?? item.int("listid").map(String.init) ?? ""
        // Pass `list_create_gid || global_collection_id` straight through to
        // /playlist/track/all. Only reconstruct a `collection_3_...` gid when
        // both are empty/missing — a rebuilt gid is wrong for collected-album
        // rows whose real gid lives in `global_collection_id`.
        let rawGID = item.string("list_create_gid") ?? ""
        let fallbackGID = item.string("global_collection_id") ?? ""
        let name = item.string("name") ?? ""

        let creator = item.string("list_create_userid")
            ?? item.int("list_create_userid").map(String.init)
            ?? ""
        let listCreateListID = item.string("list_create_listid")
            ?? item.int("list_create_listid").map(String.init)
            ?? ""
        let gid: String
        if !rawGID.isEmpty, rawGID != "0" {
            gid = rawGID
        } else if !fallbackGID.isEmpty, fallbackGID != "0" {
            gid = fallbackGID
        } else if !creator.isEmpty, !listCreateListID.isEmpty {
            gid = "collection_3_\(creator)_\(listCreateListID)_0"
        } else {
            gid = ""
        }
        guard !name.isEmpty, (!gid.isEmpty || !listID.isEmpty) else { return nil }

        let isLiked = name == "我喜欢"
        let isOwned = isLiked || (!userID.isEmpty && creator == userID)
        let hasAuthors = isTruthyAuthors(item["authors"])

        let kind: Playlist.Kind
        if isLiked {
            kind = .liked
        } else if isOwned {
            kind = .owned
        } else if hasAuthors {
            kind = .collectedAlbum
        } else {
            kind = .collected
        }

        let identity = gid.isEmpty ? "list-\(listID)" : gid
        let artistHint = item.string("list_create_username")
            ?? item["authors"].array.first?.string("author_name")
            ?? item["authors"].string("author_name")
        return Playlist(
            id: identity,
            name: isLiked ? "Liked Songs" : name,
            artworkSymbol: isLiked ? "heart.fill" : (kind == .collectedAlbum ? "square.stack.fill" : "music.note.list"),
            artworkTemplate: item.string("pic") ?? item.string("sizable_cover"),
            intro: artistHint,
            songIDs: [],
            kind: kind,
            listID: listID.isEmpty ? nil : listID,
            globalCollectionID: gid.isEmpty ? nil : gid,
            count: item.int("count"),
            listCreateUserid: creator.isEmpty ? nil : creator,
            listCreateListid: listCreateListID.isEmpty ? nil : listCreateListID
        )
    }

    /// `/user/follow` mixes several follow kinds together; only `source == 7` is
    /// an artist. Small avatars are upsized from `/100/` to `/480/` for the
    /// artist detail header.
    private static func parseFollowedArtists(_ json: AnyJSON) -> [Artist] {
        let lists = json.data["lists"].array.isEmpty ? json.data.array : json.data["lists"].array
        return lists.compactMap { item in
            let source = item.int("source") ?? 0
            let singerID = item.string("singerid") ?? item.int("singerid").map(String.init)
            guard source == 7, let singerID, !singerID.isEmpty else { return nil }
            let name = item.string("nickname") ?? item.string("author_name") ?? item.string("name") ?? "Artist"
            let pic = item.string("pic")?
                .replacingOccurrences(of: "/100/", with: "/480/")
            return Artist(
                id: singerID,
                name: name,
                artworkSymbol: "person.fill",
                artworkTemplate: pic,
                singerID: singerID
            )
        }
    }

    /// A playlist row is treated as an album when `authors` is truthy.
    private static func isTruthyAuthors(_ json: AnyJSON) -> Bool {
        if json.isNull { return false }
        if !json.array.isEmpty { return true }
        if !json.dictionary.isEmpty { return true }
        if let value = json.stringValue {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "0" && trimmed != "null" && trimmed != "[]"
        }
        return false
    }
}
