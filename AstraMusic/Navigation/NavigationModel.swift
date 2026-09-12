import Foundation
import Observation

/// The window shell's navigation state: which sidebar root is selected, the
/// middle column's drill-down stack, and the lyrics / login overlays.
///
/// Extracted from `ContentView` so the shell stays a thin layout and the push /
/// pop rules live in one place: opening an item pushes a route, Esc pops one
/// level, and switching roots or signing out clears the stack (the path holds
/// account objects that a sign-out invalidates).
@Observable
final class NavigationModel {
    var section: RootSection = .forYou
    /// Drill-down stack for the selected root. Esc pops it; switching roots
    /// clears it.
    var path: [Route] = []
    var showLyrics = false
    /// Chrome must restore *before* the split view is inserted, otherwise
    /// `NavigationSplitView` lays out under `fullSizeContentView` and the
    /// library title bar stays broken. Flipped a beat *after* lyrics are
    /// inserted, and cleared before they are removed.
    var immersiveChrome = false
    var showLogin = false

    func openAlbum(_ album: Album) {
        path.append(.album(album))
    }

    func openArtist(_ artist: Artist) {
        path.append(.artist(artist))
    }

    func openPlaylist(_ playlist: Playlist) {
        path.append(.playlist(playlist))
    }

    /// Opens a pinned playlist from the sidebar, replacing the stack: a sidebar
    /// click is a fresh destination, not another drill-down level.
    func openPinnedPlaylist(_ playlist: Playlist) {
        path = [.playlist(playlist)]
    }

    /// Esc steps back one level; a no-op at the root (path empty).
    func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    /// Switching roots or signing out invalidates the objects the path holds.
    func clearPath() {
        path.removeAll()
    }

    func openLyrics() {
        showLyrics = true
        // Apply immersive chrome only after lyrics have been inserted; the
        // reverse on close avoids the split view laying out under
        // `fullSizeContentView`.
        DispatchQueue.main.async { [weak self] in
            self?.immersiveChrome = true
        }
    }

    func closeLyrics() {
        // Restore the window chrome first, then swap the split view back in on
        // the next runloop turn.
        immersiveChrome = false
        DispatchQueue.main.async { [weak self] in
            self?.showLyrics = false
        }
    }
}
