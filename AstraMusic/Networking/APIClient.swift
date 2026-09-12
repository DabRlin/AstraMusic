import Foundation

/// Thin GET client for the local KuGouMusicApi sidecar (`http://127.0.0.1:6521`).
/// Rebuilds the `Authorization` header the sidecar expects. Risk captchas are surfaced, never solved.
///
/// Two responsibilities: build the request (URL + auth header) and translate the
/// sidecar's failure envelopes into `APIError`. Callers never see raw JSON errors.
///
/// Declared as an `actor` so the shared `URLSession` and base URL are only ever
/// touched from a single isolation domain.
actor APIClient {
    var baseURL: URL
    private let session: URLSession

    init(baseURL: URL = APIConfiguration.baseURL) {
        self.baseURL = baseURL
        // Ephemeral: nothing about the sidecar traffic should land in a cache or
        // cookie store on disk. The short timeouts make a missing sidecar fail
        // fast and visibly instead of hanging the UI.
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 20
        session = URLSession(configuration: config)
    }

    func get(_ path: String, query: [String: String] = [:]) async throws -> AnyJSON {
        try await send(path: path, query: query)
    }

    private func send(path: String, query: [String: String]) async throws -> AnyJSON {
        // Paths are always relative to `baseURL`, so callers pass `/song/url`
        // style strings and never a host.
        let trimmed = path.hasPrefix("/") ? path : "/\(path)"
        guard let resolved = URL(string: trimmed, relativeTo: baseURL),
              var components = URLComponents(url: resolved.absoluteURL, resolvingAgainstBaseURL: false)
        else {
            throw APIError.invalidURL
        }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let authorization = authorizationHeader() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Any transport failure is "the local service is not answering" from
            // the user's point of view, so it becomes one actionable message.
            throw APIError.unreachable(SidecarController.unavailableMessage)
        }

        // Kugou reports failures inside the body with HTTP 200 surprisingly often,
        // so a non-2xx is treated as a hint first: inspect the body, then fall back
        // to the bare status code.
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if let json = try? AnyJSON(data: data) {
                try throwIfAPIFailure(json)
            }
            throw APIError.httpStatus(http.statusCode)
        }

        let json = try AnyJSON(data: data)
        try throwIfAPIFailure(json)
        return json
    }

    /// Rebuilds the semicolon-joined header the sidecar expects, from the current
    /// session and device. Built per request on purpose: logging in or out takes
    /// effect on the very next call, with no cached header to invalidate.
    private func authorizationHeader() -> String? {
        var parts: [String] = []
        if let user = SessionStore.user {
            if !user.token.isEmpty { parts.append("token=\(user.token)") }
            if !user.userID.isEmpty { parts.append("userid=\(user.userID)") }
            if let t1 = user.t1, !t1.isEmpty { parts.append("t1=\(t1)") }
        }
        if let device = SessionStore.device {
            if let dfid = device.dfid, !dfid.isEmpty { parts.append("dfid=\(dfid)") }
            if let mid = device.mid, !mid.isEmpty { parts.append("KUGOU_API_MID=\(mid)") }
            if let guid = device.guid, !guid.isEmpty { parts.append("KUGOU_API_GUID=\(guid)") }
            if let serverDev = device.serverDev, !serverDev.isEmpty { parts.append("KUGOU_API_DEV=\(serverDev)") }
            if let mac = device.mac, !mac.isEmpty { parts.append("KUGOU_API_MAC=\(mac)") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ";")
    }

    /// Maps Kugou's failure conventions onto typed errors. Order matters: the risk
    /// check is the most specific signal and must win over the generic `status == 0`
    /// handling below it.
    private func throwIfAPIFailure(_ json: AnyJSON) throws {
        // `error_code` is read from the top level or from a nested `data`.
        if json.errorCode == 20028 {
            throw APIError.riskVerificationRequired
        }
        // `status` is the *top-level* field only. `status == 0` (or absent) is the
        // generic failure case; one specific variant is a phone linked to several
        // accounts, which the login UI needs as structured data rather than text.
        if json.status == 0 || json.status == nil {
            let accounts = json.data["info_list"].array.compactMap { item -> LinkedAccount? in
                let id = item.string("userid") ?? item.int("userid").map(String.init)
                guard let id, !id.isEmpty else { return nil }
                return LinkedAccount(
                    userID: id,
                    nickname: item.string("nickname") ?? id,
                    avatarURL: item.string("pic")
                )
            }
            if !accounts.isEmpty {
                throw APIError.multipleAccounts(accounts)
            }
        }
        if json.status == 2 {
            throw APIError.loginExpired
        }
        let message = json.errorMessage.lowercased()
        if message.contains("验证") || message.contains("captcha") {
            throw APIError.captchaRequired
        }
        if json.status == 0, let message = json.stringError, !message.isEmpty {
            throw APIError.server(message)
        }
    }
}

/// Small JSON bag so we don't generate Decodable types for every sidecar payload.
///
/// The sidecar returns loosely-typed, inconsistently-nested JSON (the same field
/// can be top level or under `data`, a number or a string). This wraps
/// `JSONSerialization` and offers forgiving, typed accessors; every accessor
/// returns `nil`/empty instead of throwing, so parsing code reads as a series of
/// fallbacks. Only the small number of shapes the app really needs are modelled.
///
/// `@unchecked` because `object` is `Any`. It only ever holds `JSONSerialization`
/// output (`NSDictionary` / `NSArray` / `NSString` / `NSNumber` / `NSNull`), which
/// is immutable once parsed, and this type neither mutates it nor hands it out for
/// mutation — so crossing the `APIClient` actor boundary is safe. Keeping
/// `init(_:)` private is what makes that a guarantee instead of an intention.
struct AnyJSON: @unchecked Sendable {
    private let object: Any

    init(data: Data) throws {
        object = try JSONSerialization.jsonObject(with: data)
    }

    private init(_ object: Any) {
        self.object = object
    }

    /// Top-level envelope only. Nested `data.status` is used by QR login (0/2/4).
    var status: Int? { int("status") }
    var errorCode: Int? { int("error_code") ?? data.int("error_code") }

    var errorMessage: String {
        stringError ?? ""
    }

    /// Best-effort error text, probing the spellings and nesting levels Kugou uses.
    var stringError: String? {
        if let value = string("error"), !value.isEmpty { return value }
        if let value = string("message"), !value.isEmpty { return value }
        if let value = data.string("error"), !value.isEmpty { return value }
        if let value = data.string("message"), !value.isEmpty { return value }
        if let value = data.stringValue, !value.isEmpty { return value }
        return nil
    }

    /// Unwrapping accessor: returns the nested `data` payload when there is one,
    /// otherwise this value. Lets call sites read `json.data.string("x")` without
    /// caring whether the endpoint wrapped its payload.
    var data: AnyJSON {
        if let nested = dictionary["data"] {
            return AnyJSON(nested)
        }
        return self
    }

    /// Never fails: a missing key yields a null-backed value, so lookups can be
    /// chained without `if let` noise. Check `isNull` when the difference matters.
    subscript(_ key: String) -> AnyJSON {
        if let nested = dictionary[key] {
            return AnyJSON(nested)
        }
        return AnyJSON(NSNull())
    }

    var dictionary: [String: Any] {
        object as? [String: Any] ?? [:]
    }

    var array: [AnyJSON] {
        (object as? [Any])?.map(AnyJSON.init) ?? []
    }

    var stringValue: String? {
        if let value = object as? String { return value }
        if let value = object as? NSNumber { return value.stringValue }
        return nil
    }

    var intValue: Int? {
        if let value = object as? Int { return value }
        if let value = object as? NSNumber { return value.intValue }
        if let value = object as? String { return Int(value) }
        return nil
    }

    var doubleValue: Double? {
        if let value = object as? Double { return value }
        if let value = object as? NSNumber { return value.doubleValue }
        if let value = object as? String { return Double(value) }
        return nil
    }

    func string(_ key: String) -> String? {
        self[key].stringValue
    }

    func int(_ key: String) -> Int? {
        self[key].intValue
    }

    func double(_ key: String) -> Double? {
        self[key].doubleValue
    }

    /// First non-empty string among `keys`; numbers are stringified.
    /// Long `??` chains of `String?` are slow to type-check, so call sites
    /// that probe several spellings of a field use this instead.
    func firstString(_ keys: [String]) -> String? {
        for key in keys {
            if let value = string(key), !value.isEmpty { return value }
        }
        return nil
    }

    /// True for `NSNull`, an empty object, or a scalar that stringifies to nothing.
    var isNull: Bool {
        object is NSNull || dictionary.isEmpty && !(object is [Any]) && stringValue == nil
    }
}
