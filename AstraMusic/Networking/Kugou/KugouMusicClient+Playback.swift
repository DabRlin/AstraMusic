import Foundation

/// Stream-URL resolution: the `/privilege/lite` → `/song/url` path, candidate
/// selection, and its quality / auth-rethrow helpers.
extension KugouMusicClient {

    /// Resolves a playable URL, trying a few candidate hashes in order.
    ///
    /// The HQ hash on a search row is not always the one privileges apply to, so
    /// `/privilege/lite` is consulted for the canonical 128 hash and both are
    /// tried. Quality is fixed at 128 — this is the only tier the project requests.
    ///
    /// Login is required: there are no guest streams, and preview clips
    /// (`free_part=1`) are deliberately not used. Auth / risk failures are
    /// re-thrown immediately rather than retried as if the hash were wrong.
    func playbackURL(for song: Song) async throws -> URL {
        guard let hash = song.hash, !hash.isEmpty else {
            throw APIError.empty
        }
        let original = hash.lowercased()

        // No guest streams. Preview clips (`free_part=1`) are not used.
        if !SessionStore.isLoggedIn {
            throw APIError.loginExpired
        }

        var seen = Set([original])
        var candidates: [(hash: String, quality: String)] = [(original, "128")]
        func enqueue(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            let lowered = value.lowercased()
            guard seen.insert(lowered).inserted else { return }
            candidates.insert((lowered, "128"), at: 0)
        }
        enqueue(song.fileHash)
        do {
            let privilege = try await api.get("/privilege/lite", query: ["hash": original])
            if let mapped = Self.qualityOptions(from: privilege).first(where: { $0.quality == "128" }) {
                enqueue(mapped.hash)
            }
        } catch {
            try Self.rethrowAuthOrRisk(error)
        }

        var lastError: Error = APIError.server("Could not resolve a stream URL.")
        for candidate in candidates {
            do {
                return try await fetchSongURL(query: [
                    "hash": candidate.hash,
                    "quality": candidate.quality,
                    "ppage_id": "356753938",
                ])
            } catch {
                try Self.rethrowAuthOrRisk(error)
                lastError = error
            }
        }
        throw lastError
    }

    /// Calls `/song/url` for one hash and picks a usable URL.
    ///
    /// `status == 3` is Kugou's explicit "blocked (copyright)" answer; anything
    /// other than 1 with a non-empty `url[0]` is a failure. Video streams (`mp4`)
    /// are rejected — the player expects audio.
    private func fetchSongURL(query: [String: String]) async throws -> URL {
        let json = try await api.get("/song/url", query: query)
        let status = json.int("status") ?? json.data.int("status")
        if status == 3 {
            throw APIError.server("This track is not available (copyright).")
        }
        // Only `status === 1` with a non-empty `url[0]` is a playable stream.
        if status != 1 {
            throw APIError.server(json.stringError ?? "Could not resolve a stream URL.")
        }
        let ext = (json.string("extName") ?? json.data.string("extName"))?.lowercased()
        if ext == "mp4" {
            throw APIError.server("This result is a video stream, not audio.")
        }
        guard let url = Self.firstPlaybackURL(in: json) else {
            throw APIError.server("No stream URL in the /song/url response.")
        }
        return url
    }

    /// Reads `url[0]` from the unwrapped sidecar body.
    /// The tracker payload may put `url` at the top level or under `data`, as an array or a string.
    private static func firstPlaybackURL(in json: AnyJSON) -> URL? {
        let bags = [json, json.data]
        var candidates: [String] = []
        for bag in bags {
            candidates.append(contentsOf: stringList(bag["url"]))
            candidates.append(contentsOf: stringList(bag["backupUrl"]))
            candidates.append(contentsOf: stringList(bag["backup_url"]))
            if let value = bag.string("play_url") { candidates.append(value) }
        }
        let urls = candidates.compactMap { URL(string: $0) }
        return urls.first(where: { $0.scheme?.lowercased() == "https" }) ?? urls.first
    }

    /// Accepts either a real JSON array of strings or a bare string; yields
    /// nothing for anything else.
    private static func stringList(_ json: AnyJSON) -> [String] {
        if let value = json.stringValue, !value.isEmpty, !value.hasPrefix("[") {
            return [value]
        }
        return json.array.compactMap(\.stringValue).filter { !$0.isEmpty }
    }

    /// Quality options: each privilege row plus `relate_goods`, keyed by quality.
    ///
    /// `level == 0` means the tier exists but is not available to this account, so
    /// those rows are skipped; only qualities in `allowed` are considered. The
    /// caller currently only looks up the 128 tier.
    private static func qualityOptions(from json: AnyJSON) -> [(quality: String, hash: String)] {
        let allowed: Set<String> = ["128", "320", "flac", "high", "viper_atmos", "viper_clear", "viper_tape"]
        var seen = Set<String>()
        var result: [(quality: String, hash: String)] = []
        let rows = json.data.array.isEmpty ? json.array : json.data.array
        for item in rows {
            for variant in [item] + item["relate_goods"].array {
                let quality = variant.string("quality") ?? ""
                let hash = variant.string("hash") ?? ""
                let level = variant.int("level") ?? 1
                guard allowed.contains(quality), !hash.isEmpty, level != 0, seen.insert(quality).inserted else {
                    continue
                }
                result.append((quality, hash))
            }
        }
        return result
    }

    /// Re-throws authentication / risk errors and swallows everything else.
    ///
    /// Used inside the candidate-hash loop: a "bad hash" failure should fall
    /// through to the next candidate, but a login or risk-check failure must stop
    /// immediately instead of being retried as if the hash were wrong.
    private static func rethrowAuthOrRisk(_ error: Error) throws {
        if let apiError = error as? APIError {
            switch apiError {
            case .riskVerificationRequired, .captchaRequired, .loginExpired:
                throw apiError
            default:
                break
            }
        }
    }
}
