import Foundation

/// Local queue behaviour only — no Kugou API involved.
///
/// `rawValue` is what gets persisted in `UserDefaults` (see the extension
/// below), so the numeric values are a storage contract: never renumber them.
/// `allCases` order is also the order `PlaybackModeButton` cycles through.
enum PlaybackMode: Int, CaseIterable, Identifiable, Codable {
    case shuffle = 0
    case repeatList = 1
    case repeatOne = 2
    case sequential = 3

    var id: Int { rawValue }

    /// User-facing label; also used as the button's tooltip and a11y label.
    var title: String {
        switch self {
        case .shuffle: "Shuffle"
        case .repeatList: "Repeat List"
        case .repeatOne: "Repeat One"
        case .sequential: "Play in Order"
        }
    }

    /// SF Symbol name for the current mode.
    var icon: String {
        switch self {
        case .shuffle: "shuffle"
        case .repeatList: "repeat"
        case .repeatOne: "repeat.1"
        case .sequential: "list.number"
        }
    }

    /// Used when nothing has been persisted yet (fresh install / legacy key).
    static var `default`: PlaybackMode { .repeatList }
}

extension PlaybackMode {
    // Base key; per-account slots append "_<userid>" (see `key(for:)`).
    private static let defaultsKey = "player_playback_mode"

    /// Playback mode is a per-account preference, so each Kugou user gets their
    /// own slot. Signed-out playback and preferences written before this change
    /// fall back to the account-agnostic key.
    private static func key(for userID: String?) -> String {
        guard let userID, !userID.isEmpty else { return defaultsKey }
        return "\(defaultsKey)_\(userID)"
    }

    /// Resolution order: the current user's slot, then the account-agnostic key
    /// (written by older builds or signed-out sessions), then `.default`.
    static func loadPersisted(userID: String?) -> PlaybackMode {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: key(for: userID)) as? Int,
           let mode = PlaybackMode(rawValue: raw) {
            return mode
        }
        if let raw = defaults.object(forKey: defaultsKey) as? Int,
           let mode = PlaybackMode(rawValue: raw) {
            return mode
        }
        return .default
    }

    /// Writes only the per-account slot; the legacy key is intentionally left
    /// untouched so a signed-out session can still read it.
    func persist(userID: String?) {
        UserDefaults.standard.set(rawValue, forKey: Self.key(for: userID))
    }
}
