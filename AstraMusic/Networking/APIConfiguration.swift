import Foundation

/// Resolves the base URL of the local API sidecar.
///
/// Precedence: a UserDefaults override under `apiBaseURL` wins; otherwise
/// `defaultBaseURL`. Only `http` / `https` overrides are accepted, so a
/// malformed stored value falls back rather than breaking every request.
enum APIConfiguration {
    /// Where the sidecar listens when nothing overrides it.
    static let defaultBaseURL = URL(string: "http://127.0.0.1:6521")!
    private static let defaultsKey = "apiBaseURL"

    /// Effective base URL.
    ///
    /// Read once when an `APIClient` is constructed, so changing it does not
    /// affect clients that already exist — new instances pick it up.
    static var baseURL: URL {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let url = URL(string: raw),
           let scheme = url.scheme,
           ["http", "https"].contains(scheme)
        {
            return url
        }
        return defaultBaseURL
    }

    /// Persists an override for subsequent launches.
    ///
    /// Intended for the Settings screen; nothing calls it yet.
    static func setBaseURL(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: defaultsKey)
    }
}
