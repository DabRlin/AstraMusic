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
/// Ordering matters: the wiring runs in `onAppear`, before `bootstrap()` on the
/// `task`, so nothing hits the network with a half-configured graph.
@main
struct AstraMusicApp: App {
    @State private var player = PlayerStore()
    @State private var library = LibraryStore()
    @State private var auth = AuthStore()

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
                    await auth.bootstrap()
                }
        }
        .defaultSize(width: Theme.windowDefaultSize.width, height: Theme.windowDefaultSize.height)
        .windowResizability(.contentMinSize)
    }
}
