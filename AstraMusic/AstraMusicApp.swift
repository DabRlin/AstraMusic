import SwiftUI

/// App entry point.
///
/// Owns the three stores and injects them into the view tree. The stores do not
/// reference each other; all coupling is wired up here:
///
/// - `player.musicClient = auth.client` — playback resolves through the same
///   authenticated client as everything else.
/// - `auth.attach(_:player:)` — installs the cloud write closures on
///   `LibraryStore`, which is what keeps song rows from having to hold `AuthStore`.
/// - `player.onSongStarted` — records a play into the library. This is the only
///   source of "Recent"; there is no `/user/listen` call.
///
/// `sidecar` also lives here: it starts the bundled API process before anything
/// talks to the network (see `SidecarController`).
///
/// Ordering matters: the wiring runs in `onAppear`, before `bootstrap()` on the
/// `task`, so nothing hits the network with a half-configured graph.
///
/// The stores are built in `init` rather than as property initializers so
/// `SandboxMigration` can run first — they read `UserDefaults` (device, session,
/// playback mode) as they are constructed, and that state may still be inside the
/// old sandbox container.
@main
struct AstraMusicApp: App {
    @State private var sidecar: SidecarController
    @State private var player: PlayerStore
    @State private var library: LibraryStore
    @State private var auth: AuthStore

    init() {
        SandboxMigration.migratePreferencesIfNeeded()
        _sidecar = State(initialValue: SidecarController())
        _player = State(initialValue: PlayerStore())
        _library = State(initialValue: LibraryStore())
        _auth = State(initialValue: AuthStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(player)
                .environment(library)
                .environment(auth)
                .frame(
                    minWidth: Theme.windowMinSize.width,
                    minHeight: Theme.windowMinSize.height
                )
                .onAppear {
                    player.musicClient = auth.client
                    auth.attach(library, player: player)
                    player.onSongStarted = { song in
                        library.recordPlay(song)
                    }
                }
                .task {
                    // The sidecar has to be up before `bootstrap()` registers the
                    // device — there is no retry, a failure simply becomes the
                    // "service is unavailable" copy.
                    await sidecar.start()
                    await auth.bootstrap()
                }
        }
        .defaultSize(width: Theme.windowDefaultSize.width, height: Theme.windowDefaultSize.height)
        .windowResizability(.contentMinSize)
    }
}
