import SwiftUI

/// Root content view: shows either the library chrome (sidebar + middle column +
/// queue) or, when lyrics are open, the full-window `LyricsView`.
///
/// A thin shell: navigation state lives in `NavigationModel`, the middle-column
/// routing in `DetailRouter`, and the three stores are injected from
/// `AstraMusicApp`.
struct ContentView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(LibraryStore.self) private var library
    @State private var nav = NavigationModel()
    @State private var libraryAlertMessage: String?
    @SceneStorage("showQueue") private var showQueue = true
    @SceneStorage("queueWidth") private var queueWidth = Double(Theme.queueWidth)
    /// Live width while the handle is being dragged. `SceneStorage` is only
    /// written on release, so a drag doesn't hit disk on every frame.
    @State private var liveQueueWidth: CGFloat?

    var body: some View {
        Group {
            if nav.showLyrics {
                LyricsView(onClose: nav.closeLyrics)
            } else {
                libraryChrome
            }
        }
        .background(WindowChromeBridge(immersive: nav.immersiveChrome))
        // One bridge instance for the whole window: it snapshots the original
        // NSWindow title-bar style once and restores it when lyrics close.
        .tint(Theme.accent)
        .animation(.easeInOut(duration: 0.28), value: nav.showLyrics)
        .sheet(isPresented: $nav.showLogin) {
            LoginView { nav.showLogin = false }
                .environment(auth)
        }
        .alert("Library", isPresented: Binding(
            get: { libraryAlertMessage != nil },
            set: { if !$0 { libraryAlertMessage = nil } }
        )) {
            Button("OK", role: .cancel) { libraryAlertMessage = nil }
        } message: {
            Text(libraryAlertMessage ?? "")
        }
        .onChange(of: library.accountActionMessage) { _, message in
            // Account actions (like / add / follow) report their failure here;
            // surface it as an alert and clear the store field.
            guard let message else { return }
            libraryAlertMessage = message
            library.accountActionMessage = nil
        }
    }

    private var libraryChrome: some View {
        // Sidebar is the left column; everything inside `detail` is the middle
        // column plus the optional queue. Esc is handled on the split view.
        NavigationSplitView {
            SidebarView(section: $nav.section, onOpenPinnedPlaylist: nav.openPinnedPlaylist)
        } detail: {
            HStack(spacing: 0) {
                DetailRouter(nav: nav)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(0)

                if showQueue {
                    // The queue claims its fixed width while the stack yields, so
                    // the column never squeezes the detail content.
                    QueueView()
                        .frame(width: liveQueueWidth ?? CGFloat(queueWidth))
                        .layoutPriority(1)
                        .clipped()
                        // The resize handle floats over the queue's leading edge
                        // instead of taking layout width, so the two columns sit
                        // flush with no gap at the divider.
                        .overlay(alignment: .leading) {
                            QueueResizeHandle(
                                width: queueWidthBinding,
                                onCommit: commitQueueWidth
                            )
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showQueue)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    accountButton
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showQueue.toggle()
                    } label: {
                        Label("Queue", systemImage: "sidebar.trailing")
                    }
                    .help(showQueue ? "Hide Queue" : "Show Queue")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                NowPlayingBar(onOpenLyrics: nav.openLyrics)
            }
            .toolbar(.visible, for: .windowToolbar)
        }
        .onChange(of: nav.section) { _, _ in nav.clearPath() }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            // Signing out invalidates the account objects the path may hold.
            if !loggedIn { nav.clearPath() }
        }
        // Esc steps back one level; a no-op at the root (path empty).
        .onExitCommand { nav.pop() }
    }

    @ViewBuilder
    private var accountButton: some View {
        // Signed-in: name + library actions in a menu. Signed-out: a sign-in
        // button whose help text distinguishes "no account" from "sidecar down".
        if auth.isLoggedIn {
            Menu {
                Text(auth.displayName)
                Button {
                    Task { await refreshAccountLibrary() }
                } label: {
                    Label("Refresh Library", systemImage: "arrow.clockwise")
                }
                // Explicit menu action, not polling.
                .disabled(library.isRefreshingAccount)
                Button("Sign Out", role: .destructive, action: auth.logout)
            } label: {
                Label(auth.displayName, systemImage: "person.crop.circle.fill")
            }
        } else {
            Button {
                nav.showLogin = true
            } label: {
                Label("Sign In", systemImage: "person.crop.circle")
            }
            .help(auth.apiReachable ? "Sign in with Kugou" : SidecarController.unavailableMessage)
        }
    }

    /// Live drag binding: reads the in-progress width and feeds it back into
    /// `liveQueueWidth` while dragging; `commitQueueWidth` persists on release.
    private var queueWidthBinding: Binding<CGFloat> {
        Binding(
            get: { liveQueueWidth ?? CGFloat(queueWidth) },
            set: { liveQueueWidth = $0 }
        )
    }

    /// Persist the drag result once instead of writing `SceneStorage` per frame.
    private func commitQueueWidth() {
        guard let liveQueueWidth else { return }
        queueWidth = Double(liveQueueWidth)
        self.liveQueueWidth = nil
    }

    private func refreshAccountLibrary() async {
        // `refreshAccountLibrary` throws nothing; failures land in
        // `library.accountError`.
        await auth.refreshAccountLibrary()
        if let error = library.accountError {
            libraryAlertMessage = error
        }
    }
}

#Preview {
    PreviewRoot()
}

private struct PreviewRoot: View {
    @State private var player = PlayerStore()
    @State private var library = LibraryStore(persistToDisk: false)
    @State private var auth = AuthStore()

    var body: some View {
        ContentView()
            .environment(player)
            .environment(library)
            .environment(auth)
            .frame(width: 1280, height: 800)
            .onAppear {
                // Mirror the wiring `AstraMusicApp` performs at launch.
                player.musicClient = auth.client
                auth.attach(library, player: player)
                if player.queue.isEmpty {
                    player.resetQueue()
                }
            }
    }
}
