import AppKit
import SwiftUI

/// Applies immersive chrome only while lyrics are showing.
/// A single instance lives on `ContentView` so we snapshot the original
/// window once (library chrome) and restore it before the split view
/// is asked to lay out again.
struct WindowChromeBridge: NSViewRepresentable {
    var immersive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.coordinator = context.coordinator
        view.immersive = immersive
        return view
    }

    func updateNSView(_ view: CaptureView, context: Context) {
        // Re-apply on every update so toggling `immersive` flips the chrome
        // immediately rather than on the next window event.
        view.coordinator = context.coordinator
        view.immersive = immersive
        view.applyIfPossible()
    }

    static func dismantleNSView(_ view: CaptureView, coordinator: Coordinator) {
        // The bridge may be torn down while immersive, so always restore;
        // otherwise the window would keep transparent, full-size chrome.
        coordinator.restore(view.window)
    }

    final class Coordinator {
        /// The window chrome captured before immersion. Restoring from this
        /// snapshot (rather than guessing system defaults) is what makes the
        /// library title bar exactly what it was before lyrics opened.
        private var snapshot: Snapshot?

        func apply(immersive: Bool, to window: NSWindow) {
            // Capture the pre-existing chrome the first time we run in the
            // non-immersive (library) state.
            if snapshot == nil, !immersive {
                snapshot = Snapshot(window)
            }
            if immersive {
                // Fallback for the case where immersive is applied without ever
                // having seen the non-immersive pass.
                if snapshot == nil {
                    snapshot = Snapshot(window)
                }
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                window.titlebarSeparatorStyle = .none
                window.styleMask.insert(.fullSizeContentView)
                window.isMovableByWindowBackground = true
            } else {
                restore(window)
            }
        }

        func restore(_ window: NSWindow?) {
            guard let window else { return }
            // Prefer the captured snapshot; fall back to the standard window
            // chrome only when nothing was ever captured.
            if let snapshot {
                snapshot.restore(window)
            } else {
                Snapshot.systemDefault.restore(window)
            }
        }
    }

    /// Snapshot of every `NSWindow` property this bridge mutates. Storing the
    /// full set means restore never has to assume what the library chrome was.
    struct Snapshot {
        var containsFullSizeContentView: Bool
        var titlebarAppearsTransparent: Bool
        var titleVisibility: NSWindow.TitleVisibility
        var titlebarSeparatorStyle: NSTitlebarSeparatorStyle
        var isMovableByWindowBackground: Bool

        static let systemDefault = Snapshot(
            containsFullSizeContentView: false,
            titlebarAppearsTransparent: false,
            titleVisibility: .visible,
            titlebarSeparatorStyle: .automatic,
            isMovableByWindowBackground: false
        )

        init(_ window: NSWindow) {
            containsFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
            titlebarAppearsTransparent = window.titlebarAppearsTransparent
            titleVisibility = window.titleVisibility
            titlebarSeparatorStyle = window.titlebarSeparatorStyle
            isMovableByWindowBackground = window.isMovableByWindowBackground
        }

        init(
            containsFullSizeContentView: Bool,
            titlebarAppearsTransparent: Bool,
            titleVisibility: NSWindow.TitleVisibility,
            titlebarSeparatorStyle: NSTitlebarSeparatorStyle,
            isMovableByWindowBackground: Bool
        ) {
            self.containsFullSizeContentView = containsFullSizeContentView
            self.titlebarAppearsTransparent = titlebarAppearsTransparent
            self.titleVisibility = titleVisibility
            self.titlebarSeparatorStyle = titlebarSeparatorStyle
            self.isMovableByWindowBackground = isMovableByWindowBackground
        }

        func restore(_ window: NSWindow) {
            // Insert/remove rather than assign, so a flag we never changed is
            // left untouched.
            if containsFullSizeContentView {
                window.styleMask.insert(.fullSizeContentView)
            } else {
                window.styleMask.remove(.fullSizeContentView)
            }
            window.titlebarAppearsTransparent = titlebarAppearsTransparent
            window.titleVisibility = titleVisibility
            window.titlebarSeparatorStyle = titlebarSeparatorStyle
            window.isMovableByWindowBackground = isMovableByWindowBackground
        }
    }

    final class CaptureView: NSView {
        weak var coordinator: Coordinator?
        var immersive = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The view can be created before it has a window, so re-apply when
            // the window becomes available.
            applyIfPossible()
        }

        func applyIfPossible() {
            // No window yet: nothing to configure, and no crash.
            guard let window else { return }
            coordinator?.apply(immersive: immersive, to: window)
        }
    }
}
