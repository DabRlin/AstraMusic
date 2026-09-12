import Foundation
import Security

/// The device fingerprint the sidecar (and Kugou) expects on every request.
///
/// These values are registered once via `/register/dev` and then sent in the
/// `Authorization` header; they identify the install, not the user.
struct DeviceInfo: Codable, Equatable, Sendable {
    var dfid: String?
    var mid: String?
    var guid: String?
    var serverDev: String?
    var mac: String?
}

/// A signed-in Kugou session.
///
/// The `token` is the credential; everything else is display data plus `t1`,
/// which participates in the request signature.
struct UserSession: Codable, Equatable, Sendable {
    var token: String
    var userID: String
    var t1: String?
    var nickname: String?
    var avatarURL: String?
}

/// Persistence for the session and device identity.
///
/// Split deliberately: the **token** lives in the data-protection keychain
/// (a credential), while the device fingerprint and the profile copy live in
/// `UserDefaults` (not secret, and needed before the keychain is read). Nothing
/// here is per-user; switching accounts overwrites it.
enum SessionStore {
    private static let service = "com.dang.AstraMusic"
    private static let tokenAccount = "kugou.token"
    private static let deviceKey = "kugou.device"
    private static let profileKey = "kugou.profile"

    static var device: DeviceInfo? {
        get { decode(DeviceInfo.self, defaultsKey: deviceKey) }
        set { encode(newValue, defaultsKey: deviceKey) }
    }

    /// The current session, preferring the keychain copy of the token.
    static var user: UserSession? {
        get {
            let profile = decode(UserSession.self, defaultsKey: profileKey)
            if let token = keychainToken, !token.isEmpty {
                var session = profile ?? UserSession(token: token, userID: "")
                session.token = token
                return session
            }

            // The profile is also persisted when login succeeds. Falling
            // back to it keeps the in-memory session and API authorization in
            // sync if an unsigned/ad-hoc build cannot read the data-protection
            // keychain for a moment. The keychain remains the preferred
            // source whenever it is available.
            guard let profile, !profile.token.isEmpty else { return nil }
            return profile
        }
        set {
            if let session = newValue {
                keychainToken = session.token
                encode(session, defaultsKey: profileKey)
            } else {
                keychainToken = nil
                UserDefaults.standard.removeObject(forKey: profileKey)
            }
        }
    }

    static var isLoggedIn: Bool {
        guard let user else { return false }
        return !user.token.isEmpty
    }

    /// Sign out. Clears both the keychain token and the cached profile; the
    /// device fingerprint is intentionally kept so re-login does not re-register.
    static func clearUser() {
        user = nil
    }

    /// App-private data-protection keychain. The file-based login keychain
    /// prompts for the Mac password on unsigned / ad-hoc Xcode builds.
    private static func keychainQuery(returningData: Bool = false) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if returningData {
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    /// Read/write the token as a single generic-password item. Writes replace
    /// unconditionally (delete-then-add), and the item is readable after first
    /// unlock only on this device, so it never syncs or leaves the machine.
    private static var keychainToken: String? {
        get {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(keychainQuery(returningData: true) as CFDictionary, &item)
            guard status == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            SecItemDelete(keychainQuery() as CFDictionary)
            guard let value = newValue, let data = value.data(using: .utf8) else { return }
            var query = keychainQuery()
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, defaultsKey: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Stores JSON in `UserDefaults`, removing the key when the value is `nil` so
    /// "absent" has exactly one representation.
    private static func encode<T: Encodable>(_ value: T?, defaultsKey: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }
}
