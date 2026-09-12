import Foundation

/// The login-only surface of the client: device registration and the QR / SMS /
/// password sign-in flows.
///
/// Deliberately separate from `MusicClient`, which is the account / metadata
/// surface the rest of the UI talks to — no ordinary screen should be able to
/// reach these endpoints. `AuthStore.client` is the composition
/// `any MusicClient & LoginClient`; only `AuthStore` and `LoginView` call these.
protocol LoginClient: Sendable {
    /// Registers this device and returns the fingerprint the API expects on
    /// later requests. Idempotent: a stored device with a `dfid` short-circuits.
    func registerDevice() async throws -> DeviceInfo

    /// Starts a QR login: returns the key the code is generated for.
    func qrKey() async throws -> String

    /// The QR code as a base64 payload, rendered by the login view.
    func qrImage(key: String) async throws -> String

    /// One poll of a QR login attempt; `succeeded` carries the session.
    func qrCheck(key: String) async throws -> QRLoginStatus

    /// Requests an SMS login code for a phone number.
    func sendCaptcha(mobile: String) async throws

    /// Phone + SMS code login. `userID` disambiguates when one number maps to
    /// several accounts (see `APIError.multipleAccounts`).
    func loginWithPhone(mobile: String, code: String, userID: String?) async throws -> UserSession

    /// Username / password login.
    func loginWithPassword(username: String, password: String) async throws -> UserSession
}
