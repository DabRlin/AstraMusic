import AppKit
import SwiftUI

/// Login sheet (QR / SMS / password), presented from `ContentView`.
///
/// Every call goes through `AuthStore.client`; a successful login hands the
/// session to `auth.apply`, which is what stores the token and refreshes the
/// account library. The QR poll loop is the only long-lived work here, so
/// `pollTask` must always be cancelled before a new one starts (see
/// `restartQRIfNeeded` and `onDisappear`).
struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    var onClose: () -> Void

    private enum Mode: String, CaseIterable, Identifiable {
        case qr = "QR code"
        case phone = "Phone"
        case password = "Password"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .qr
    @State private var mobile = ""
    @State private var smsCode = ""
    @State private var username = ""
    @State private var password = ""
    @State private var message: String?
    /// Blocks the submit buttons while a request is in flight, so a slow sidecar
    /// cannot be double-submitted.
    @State private var isWorking = false
    @State private var qrKey = ""
    @State private var qrImageBase64 = ""
    @State private var qrHint = "Scan with the official Kugou app"
    @State private var linkedAccounts: [LinkedAccount] = []
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Sign in")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }

            // Product constraint: no VIP claims and no captcha solving, ever.
            Text("Unofficial local API for personal learning. AstraMusic never claims VIP or solves captchas.")
                .font(.callout)
                .foregroundStyle(.secondary)

            // Only shown while the local API is unreachable; once it is up, each
            // action reports its own failure in `message`.
            if let error = auth.lastError, !auth.apiReachable {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Picker("Method", selection: $mode) {
                ForEach(Mode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { _, newValue in
                restartQRIfNeeded(newValue)
            }

            Group {
                switch mode {
                case .qr:
                    qrPane
                case .phone:
                    phonePane
                case .password:
                    passwordPane
                }
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            restartQRIfNeeded(.qr)
        }
        .onDisappear {
            // The poll must never outlive the sheet.
            pollTask?.cancel()
        }
    }

    private var qrPane: some View {
        VStack(spacing: 12) {
            if let image = qrNSImage {
                Image(nsImage: image)
                    // Keep the QR pixel-crisp; smoothing would hurt scannability.
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView("Generating QR…")
                    .frame(width: 220, height: 220)
            }
            Text(qrHint)
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Refresh code") {
                Task { await loadQR() }
            }
            .disabled(isWorking)
        }
        .frame(maxWidth: .infinity)
    }

    private var phonePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Two-step state: credentials first, then an account picker when the
            // API reports the phone is linked to several accounts.
            if linkedAccounts.isEmpty {
                TextField("Phone", text: $mobile)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField("SMS code", text: $smsCode)
                        .textFieldStyle(.roundedBorder)
                    Button("Send code") {
                        Task { await sendCode() }
                    }
                    .disabled(isWorking || mobile.isEmpty)
                }
                Button("Sign in") {
                    Task { await phoneLogin() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking || mobile.isEmpty || smsCode.isEmpty)
            } else {
                Text("This phone is linked to more than one account.")
                    .font(.callout)
                ForEach(linkedAccounts) { account in
                    Button {
                        Task { await phoneLogin(userID: account.userID) }
                    } label: {
                        HStack {
                            Text(account.nickname)
                            Spacer()
                            Text(account.userID)
                                .foregroundStyle(.secondary)
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                }
                Button("Back") {
                    linkedAccounts = []
                }
            }
        }
    }

    private var passwordPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Email / username", text: $username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            Button("Sign in") {
                Task { await passwordLogin() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isWorking || username.isEmpty || password.isEmpty)
        }
    }

    private var qrNSImage: NSImage? {
        guard !qrImageBase64.isEmpty else { return nil }
        let cleaned = qrImageBase64
            .replacingOccurrences(of: "data:image/png;base64,", with: "")
            .replacingOccurrences(of: "data:image/jpeg;base64,", with: "")
            .replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else { return nil }
        return NSImage(data: data)
    }

    private func restartQRIfNeeded(_ mode: Mode) {
        // Cancel first: switching modes or refreshing must not leave the old
        // key's poll racing the new one.
        pollTask?.cancel()
        if mode == .qr {
            Task { await loadQR() }
        }
    }

    private func loadQR() async {
        isWorking = true
        message = nil
        do {
            let key = try await auth.client.qrKey()
            qrKey = key
            qrImageBase64 = try await auth.client.qrImage(key: key)
            qrHint = "Scan with the official Kugou app"
            startPolling()
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }

    private func startPolling() {
        // Capture the key this loop belongs to, so a refreshed code's task cannot
        // consume the previous key's status.
        pollTask?.cancel()
        let key = qrKey
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.2))
                if Task.isCancelled { return }
                do {
                    let status = try await auth.client.qrCheck(key: key)
                    switch status {
                    case .waiting:
                        break
                    case .scanned(let nickname):
                        qrHint = "\(nickname) scanned — confirm on the phone"
                    case .succeeded(let session):
                        // Terminal: adopt the session and close, which stops polling.
                        auth.apply(session)
                        onClose()
                        return
                    case .expired:
                        qrHint = "Code expired"
                        message = "QR code expired. Refresh and try again."
                        return
                    }
                } catch {
                    message = error.localizedDescription
                    return
                }
            }
        }
    }

    private func sendCode() async {
        isWorking = true
        message = nil
        do {
            try await auth.client.sendCaptcha(mobile: mobile)
            message = "Code sent."
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }

    private func phoneLogin(userID: String? = nil) async {
        isWorking = true
        message = nil
        do {
            let session = try await auth.client.loginWithPhone(mobile: mobile, code: smsCode, userID: userID)
            auth.apply(session)
            onClose()
        } catch APIError.multipleAccounts(let accounts) {
            // One phone, several accounts: show a picker instead of guessing.
            linkedAccounts = accounts
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }

    private func passwordLogin() async {
        isWorking = true
        message = nil
        do {
            let session = try await auth.client.loginWithPassword(username: username, password: password)
            auth.apply(session)
            onClose()
        } catch {
            message = error.localizedDescription
        }
        isWorking = false
    }
}
