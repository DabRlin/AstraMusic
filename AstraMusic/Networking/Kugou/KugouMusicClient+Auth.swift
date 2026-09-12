import Foundation

/// Device registration, SMS / password / QR login, and session persistence.
/// This is the login-only surface, kept separate so it can become its own protocol.
extension KugouMusicClient {

    /// Registers the install and caches the fingerprint in `SessionStore`.
    ///
    /// A stored device that already has a `dfid` short-circuits the call, so this
    /// effectively runs once per install rather than once per launch.
    func registerDevice() async throws -> DeviceInfo {
        if let existing = SessionStore.device, existing.dfid != nil {
            return existing
        }
        let json = try await api.get("/register/dev")
        let payload = json.data
        let device = DeviceInfo(
            dfid: payload.string("dfid"),
            mid: payload.string("mid"),
            guid: payload.string("guid"),
            serverDev: payload.string("serverDev") ?? payload.string("server_dev"),
            mac: payload.string("mac")
        )
        guard device.dfid != nil else {
            throw APIError.empty
        }
        SessionStore.device = device
        return device
    }

    /// Requests an SMS login code for a phone number.
    func sendCaptcha(mobile: String) async throws {
        let json = try await api.get("/captcha/sent", query: ["mobile": mobile])
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Could not send the code.")
        }
    }

    /// Phone + SMS code login. `userID` disambiguates when one number maps to
    /// several accounts (see `APIError.multipleAccounts`).
    func loginWithPhone(mobile: String, code: String, userID: String? = nil) async throws -> UserSession {
        var query = ["mobile": mobile, "code": code]
        if let userID { query["userid"] = userID }
        let json = try await api.get("/login/cellphone", query: query)
        return try persistUser(from: json)
    }

    /// Username + password login.
    func loginWithPassword(username: String, password: String) async throws -> UserSession {
        let json = try await api.get("/login", query: [
            "username": username,
            "password": password,
        ])
        return try persistUser(from: json)
    }

    /// Starts a QR login: returns the key the code is generated for.
    func qrKey() async throws -> String {
        let json = try await api.get("/login/qr/key")
        if let key = json.data.string("qrcode") ?? json.data.string("key") ?? json.string("qrcode") {
            return key
        }
        throw APIError.empty
    }

    /// Returns the QR code as a base64 payload, rendered by the login view.
    func qrImage(key: String) async throws -> String {
        let json = try await api.get("/login/qr/create", query: [
            "key": key,
            "qrimg": "true",
        ])
        if let image = json.data.string("base64") ?? json.data.string("qrimg") ?? json.string("qrimg") {
            return image
        }
        throw APIError.empty
    }

    /// Polls a QR login attempt. Kugou's `data.status`: 0 expired, 2 scanned,
    /// 4 succeeded (and carries the session), anything else still waiting.
    ///
    /// The status is read from the nested `data` first; the envelope-level
    /// `status` carries a different meaning (see `AnyJSON.status`).
    func qrCheck(key: String) async throws -> QRLoginStatus {
        let json = try await api.get("/login/qr/check", query: [
            "key": key,
            "timestamp": String(Int(Date().timeIntervalSince1970 * 1000)),
        ])
        let status = json.data.int("status") ?? json.int("status") ?? 0
        switch status {
        case 2:
            let nickname = json.data.string("nickname") ?? "user"
            return .scanned(nickname: nickname)
        case 4:
            let session = try persistUser(from: json)
            return .succeeded(session)
        case 0:
            return .expired
        default:
            return .waiting
        }
    }

    /// Validates a login response, extracts the session, and persists it.
    ///
    /// `status == 0` is the failure convention. The token and user id are probed
    /// under several spellings inside `data`. Persisting happens here as a side
    /// effect, so any successful login path ends up with a stored session.
    private func persistUser(from json: AnyJSON) throws -> UserSession {
        if json.status == 0 {
            throw APIError.server(json.stringError ?? "Login failed.")
        }
        let payload = json.data
        let token = payload.string("token") ?? payload.string("Token") ?? ""
        let userID = payload.string("userid") ?? payload.string("user_id") ?? payload.int("userid").map(String.init) ?? ""
        guard !token.isEmpty else { throw APIError.empty }
        let session = UserSession(
            token: token,
            userID: userID,
            t1: payload.string("t1"),
            nickname: payload.string("nickname") ?? payload.string("user_name"),
            avatarURL: payload.string("pic") ?? payload.string("photo")
        )
        SessionStore.user = session
        return session
    }
}
