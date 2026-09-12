import Foundation

/// Two-step lyrics lookup (`/search/lyric` → `/lyric`) for a track, flattened
/// to one entry per displayed line.
extension KugouMusicClient {

    /// Two-step lyrics lookup: `/search/lyric` finds a candidate for the hash,
    /// then `/lyric` fetches the decoded body.
    ///
    /// Returns `[]` rather than throwing on any failure: lyrics are decoration,
    /// and a missing or unmatched lyric must not interrupt playback.
    func lyrics(for song: Song) async throws -> [LyricLine] {
        guard let hash = song.hash, !hash.isEmpty, !hash.hasPrefix("local_") else {
            return []
        }
        do {
            let search = try await api.get("/search/lyric", query: ["hash": hash])
            let candidates = search["candidates"].array.isEmpty
                ? search.data["candidates"].array
                : search["candidates"].array
            guard let first = candidates.first,
                  let lyricID = first.string("id") ?? first["id"].stringValue,
                  let accessKey = first.string("accesskey")
            else {
                return []
            }
            let lyric = try await api.get("/lyric", query: [
                "id": lyricID,
                "accesskey": accessKey,
                "fmt": "krc",
                "decode": "true",
            ])
            let decoded = lyric.string("decodeContent")
                ?? lyric.data.string("decodeContent")
                ?? lyric.string("content")
                ?? ""
            return LyricsParser.parseDecodedLyric(decoded)
        } catch {
            return []
        }
    }
}
