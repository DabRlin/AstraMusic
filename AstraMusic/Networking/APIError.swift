import Foundation

/// Errors produced by the networking layer, phrased for direct display.
///
/// Two cases are deliberately never auto-recovered: `.riskVerificationRequired`
/// and `.captchaRequired`. Kugou's risk checks must be completed by the user in
/// the official app — this project surfaces them and stops there.
enum APIError: LocalizedError, Equatable {
    /// The request URL could not be built (bad base URL or query item).
    case invalidURL
    /// The local API sidecar could not be reached at all — normally "not started".
    case unreachable(String)
    /// The sidecar answered with a non-2xx status.
    case httpStatus(Int)
    /// The sidecar returned an error payload; the message is already user-facing.
    case server(String)
    /// The stored session was rejected; the user has to sign in again.
    case loginExpired
    /// Kugou demands a risk check (`error_code == 20028`).
    case riskVerificationRequired
    /// Kugou demands a captcha.
    case captchaRequired
    /// One phone number maps to several accounts; the caller must ask which one.
    case multipleAccounts([LinkedAccount])
    /// The response was well-formed but carried nothing usable.
    case empty

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Invalid API URL."
        case .unreachable(let message):
            message
        case .httpStatus(let code):
            "HTTP \(code)"
        case .server(let message):
            message
        case .loginExpired:
            "Login expired. Sign in again."
        case .riskVerificationRequired:
            "Kugou asked for a risk check. Open the official app to finish it — AstraMusic will not auto-solve captchas."
        case .captchaRequired:
            "A captcha is required. Complete it in the official Kugou app."
        case .multipleAccounts:
            "This phone is linked to more than one account."
        case .empty:
            "The API returned nothing useful."
        }
    }
}

/// A Kugou account reachable from one phone number.
///
/// Only meaningful for `.multipleAccounts`: the user picks one, then the caller
/// retries the phone login with that `userID`.
struct LinkedAccount: Equatable, Identifiable, Sendable {
    var id: String { userID }
    var userID: String
    var nickname: String
    var avatarURL: String?
}

/// Polling state of a QR login attempt.
///
/// `waiting` → `scanned` → `succeeded` on the happy path; `expired` means the
/// user must refresh and scan again.
enum QRLoginStatus: Equatable, Sendable {
    case waiting
    case scanned(nickname: String)
    case succeeded(UserSession)
    case expired
}

/// A song as returned by search.
///
/// Search rows omit the identity fields that playback needs (`id` here is the
/// canonical hash, so it still lines up with library state), which is why this
/// is a separate type from `Song` and converts via `asSong()`.
struct SearchSong: Identifiable, Hashable, Sendable {
    var id: String { Song.canonicalID(hash: hash, fileHash: fileHash) }
    var hash: String
    var fileHash: String? = nil
    var fileid: String? = nil
    var title: String
    var artistName: String
    var albumTitle: String
    var duration: TimeInterval
    var artworkTemplate: String? = nil

    func asSong() -> Song {
        Song(
            id: Song.canonicalID(hash: hash, fileHash: fileHash),
            title: title,
            artistName: artistName,
            albumTitle: albumTitle,
            duration: duration,
            artworkSymbol: "music.note",
            artworkTemplate: artworkTemplate,
            hash: hash,
            fileHash: fileHash,
            fileid: fileid,
            playbackURL: nil
        )
    }
}
