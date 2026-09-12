import AppKit
import Foundation

/// Name of the executable `Tools/package.sh` copies into `Contents/MacOS`.
private let sidecarExecutableName = "AstraMusicSidecar"
/// Guards against a crash loop: after this many relaunches in one session the app
/// stops trying and lets the normal "service is unavailable" copy stand.
private let maximumRelaunches = 3

/// Owns the bundled API sidecar: launches it, knows whether it is up, and
/// reclaims it on quit.
///
/// **Fixed port.** The app always talks to `APIConfiguration.baseURL`
/// (`http://127.0.0.1:6521`). Before launching anything, `start()` checks whether
/// the port already answers and adopts it if so — that is what makes the manual
/// dev flow (`node app.js --port=6521`) and a sidecar leaked by a hard-killed
/// previous launch both work, with no pid bookkeeping and no dynamic port to
/// inject before the stores are built.
///
/// **Lifecycle.** A clean quit terminates the child. A hard kill (SIGKILL, crash)
/// cannot be intercepted, so the next launch simply adopts the survivor — orphans
/// cannot accumulate because there is only ever one port to bind.
@MainActor
final class SidecarController {
    private var process: Process?
    private var relaunchCount = 0
    private var isShuttingDown = false
    private var terminationObserver: NSObjectProtocol?
    private let probeSession: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        probeSession = URLSession(configuration: config)
    }

    /// True when the sidecar ships inside the app bundle. False when running from
    /// Xcode, where the developer starts it by hand instead.
    ///
    /// `nonisolated` so the networking layer can read it without hopping actors.
    nonisolated static var isBundled: Bool {
        Bundle.main.url(forAuxiliaryExecutable: sidecarExecutableName) != nil
    }

    /// One line saying the local service is not answering.
    ///
    /// Lives here rather than at each call site because this type is the only one
    /// that knows whether the sidecar is bundled — the actionable next step is
    /// "restart the app" for a shipped build and "start the sidecar" for a
    /// developer build, and the two must not drift apart across screens.
    nonisolated static var unavailableMessage: String {
        if isBundled {
            return "The music service isn't responding. Try restarting AstraMusic."
        }
        return "The local API isn't running. Start it with `node app.js --platform=lite --port=6521` in Sidecar/."
    }

    /// Adopts a sidecar that is already listening, or launches the bundled one.
    ///
    /// Await-able to the point of readiness so callers can register the device
    /// immediately afterwards; a failure here is not an error, it just means the
    /// network calls that follow will surface `unavailableMessage`.
    func start() async {
        guard isLocalEndpoint else { return }
        observeTermination()
        guard !(await isListening()) else { return }
        guard let binary = Bundle.main.url(forAuxiliaryExecutable: sidecarExecutableName) else { return }
        run(binary)
        await waitUntilListening()
    }

    /// Terminates the child this launch started. Does nothing when the sidecar was
    /// adopted instead — it is not ours to kill.
    func stop() {
        isShuttingDown = true
        process?.terminate()
        process = nil
    }

    private var port: Int { APIConfiguration.baseURL.port ?? 6521 }

    /// Only a loopback base URL is ours to serve. A user override pointing at a
    /// remote host is somebody else's process.
    private var isLocalEndpoint: Bool {
        guard let host = APIConfiguration.baseURL.host else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(host)
    }

    private func run(_ binary: URL) {
        let task = Process()
        task.executableURL = binary
        task.arguments = ["--platform=lite", "--port=\(port)"]
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.sidecarExited() }
        }
        do {
            try task.run()
            process = task
        } catch {
            // Leave `process` nil: readiness never arrives and the UI explains
            // itself through `unavailableMessage`.
            process = nil
        }
    }

    private func sidecarExited() {
        process = nil
        guard !isShuttingDown,
              relaunchCount < maximumRelaunches,
              let binary = Bundle.main.url(forAuxiliaryExecutable: sidecarExecutableName)
        else { return }
        relaunchCount += 1
        run(binary)
    }

    /// Polls until the port answers. The child needs an unpredictable moment to
    /// bind, so this avoids guessing a fixed sleep.
    private func waitUntilListening() async {
        for _ in 0..<40 {
            if await isListening() { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// True when *something* answers HTTP on the configured local endpoint.
    ///
    /// Deliberately requests an unknown path: any reply — including the 404
    /// Express returns — proves the port is bound. Probing a real endpoint such as
    /// `/register/dev` would tie readiness to Kugou being reachable, so an offline
    /// machine would never look ready even though the sidecar is fine.
    private func isListening() async -> Bool {
        var request = URLRequest(url: APIConfiguration.baseURL.appending(path: "health"))
        request.timeoutInterval = 2
        do {
            _ = try await probeSession.data(for: request)
            return true
        } catch {
            return false
        }
    }

    /// Terminates the child on a clean quit, which is the only exit we can see.
    private func observeTermination() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }
}
