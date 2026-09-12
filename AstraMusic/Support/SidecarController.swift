import AppKit
import Darwin
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
/// (`http://127.0.0.1:6521`). `start()` first looks at whether the port already
/// answers, which is what makes a developer's hand-started `node app.js` usable
/// without a dynamic port to inject before the stores are built.
///
/// **No orphans.** The port can be occupied by something that is *not* the running
/// app talking to a service — specifically, a copy of this same sidecar left
/// behind by a crash, a Force Quit, or a `kill`. Such a process can never be
/// reclaimed by the launch that finds it (there is no `Process` handle for it),
/// and it would keep serving stale code after the app is updated. So `start()`
/// identifies the listener and, when it is our own bundled sidecar, replaces it
/// rather than adopting it. Anything else — a developer's `node app.js`, a sidecar
/// the user points the app at — is adopted and left alone, because it is not ours
/// to kill.
///
/// **Every exit path reaps the child**:
/// - a Quit (⌘Q, Dock, logout, restart) fires `willTerminateNotification`;
/// - `SIGTERM`/`SIGINT` are captured and turned into the same shutdown, because
///   AppKit does not run its termination sequence for a raw signal;
/// - a hard kill cannot be intercepted, which is exactly what the takeover logic
///   above exists to clean up on the next launch.
@MainActor
final class SidecarController {
    private var process: Process?
    private var relaunchCount = 0
    private var isShuttingDown = false
    private var terminationObserver: NSObjectProtocol?
    private var signalSources: [DispatchSourceSignal] = []
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
        observeSignals()

        if await isListening() {
            let reclaimed = await reclaimLeakedSidecar()
            // Not ours (a developer's `node app.js`, a user-supplied service):
            // adopt it and leave it running when we quit.
            guard !reclaimed.isEmpty else { return }
            if !(await waitForPortToClose(attempts: 12)) {
                // The sidecar has no signal handlers, so SIGTERM should always be
                // enough — this is the belt-and-braces case for a wedged process
                // holding the port.
                for pid in reclaimed { kill(pid, SIGKILL) }
                _ = await waitForPortToClose(attempts: 12)
            }
        }

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

    // MARK: - Leak reclamation

    /// SIGTERMs any copy of our own bundled sidecar that is sitting on the port.
    ///
    /// Returns the pids it signalled so the caller can escalate, or an empty array
    /// when the listener is something we must not touch.
    private func reclaimLeakedSidecar() async -> [pid_t] {
        var reclaimed: [pid_t] = []
        for pid in await Self.listeningPIDs(on: port) {
            guard let path = await Self.executablePath(of: pid),
                  Self.isOwnBundledSidecar(at: path)
            else { continue }
            kill(pid, SIGTERM)
            reclaimed.append(pid)
        }
        return reclaimed
    }

    /// Polls until nothing answers on the port. True when it closed.
    private func waitForPortToClose(attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if !(await isListening()) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// PIDs listening on `port`.
    ///
    /// `-sTCP:LISTEN` matters: without it `lsof` also returns every process that
    /// merely holds a client connection to the port.
    private nonisolated static func listeningPIDs(on port: Int) async -> [pid_t] {
        let output = await capture("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return output.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
    }

    /// Absolute path of the executable `pid` is running, or nil when it cannot be
    /// read (another user's process).
    ///
    /// Two `lsof` calls, because `-i` and `-d` both select *files*: asking for them
    /// together matches nothing, since a listening socket is not an executable.
    /// `-Fn` prints one `n<name>` line per match and the executable comes first
    /// (the dynamic linker follows it).
    private nonisolated static func executablePath(of pid: pid_t) async -> String? {
        let output = await capture("/usr/sbin/lsof", ["-p", String(pid), "-a", "-d", "txt", "-Fn"])
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    /// True when `path` is the sidecar inside *this* app bundle. The name is
    /// checked as well as the prefix, so an unrelated process that happens to sit
    /// under the same directory is not mistaken for ours.
    private nonisolated static func isOwnBundledSidecar(at path: String) -> Bool {
        guard (path as NSString).lastPathComponent == sidecarExecutableName else { return false }
        return path.hasPrefix(Bundle.main.bundleURL.path + "/")
    }

    /// Runs a short-lived helper and returns its standard output.
    ///
    /// Off the main actor because these block while the child runs, and `start()`
    /// calls them on the launch path. `lsof` is used because it is the only tool
    /// that maps a listening socket back to the process holding it.
    private nonisolated static func capture(_ executable: String, _ arguments: [String]) async -> String {
        await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            let output = Pipe()
            task.standardOutput = output
            task.standardError = Pipe()
            do {
                try task.run()
            } catch {
                return ""
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    // MARK: - Readiness probe

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

    // MARK: - Termination

    /// Terminates the child on a clean quit.
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

    /// Turns `SIGTERM`/`SIGINT` into the same shutdown a Quit runs.
    ///
    /// AppKit only runs its termination sequence for a Quit Apple event, so a bare
    /// `kill` would take the app down without ever reaching `stop()` and leave the
    /// child holding the port. A dispatch source is used rather than `signal(2)`
    /// because only the former may safely touch `Process` — the handler runs on
    /// the main queue instead of in a signal context.
    private func observeSignals() {
        guard signalSources.isEmpty else { return }
        for number in [SIGTERM, SIGINT] {
            // Resume the signal first: the dispatch source observes delivery, and
            // the default action (terminate here and now) must not also fire.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.terminateForSignal() }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Reaps the child and exits.
    ///
    /// Deliberately not `NSApplication.terminate`, which runs the cancellable
    /// normal-quit sequence — a signal must not be something the app can refuse.
    /// `Process.terminate()` is enough to end the sidecar: its source registers no
    /// signal handlers, so the default disposition applies.
    private func terminateForSignal() {
        stop()
        exit(EXIT_SUCCESS)
    }
}
