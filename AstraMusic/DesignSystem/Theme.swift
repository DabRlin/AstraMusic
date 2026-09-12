import SwiftUI

/// Single source of truth for the app's colors and layout metrics.
///
/// These values are shared across otherwise unrelated views (the sidebar width
/// is used by both the split view and the lyrics chrome), so changing one has
/// wider reach than it looks.
enum Theme {
    /// Brand accent, ≈ `#7C5CFF`. The same color is also installed as the
    /// asset-catalog `AccentColor`, which is what colors system controls
    /// (`.bordered` button icons, focus rings) — `Theme.accent` alone cannot.
    static let accent = Color(red: 0.49, green: 0.36, blue: 1.0)
    /// Lighter accent for secondary emphasis.
    static let accentSoft = Color(red: 0.72, green: 0.64, blue: 1.0)

    static let sidebarWidth: CGFloat = 220
    /// Default width of the queue column. It is user-resizable between
    /// `queueMinWidth` and `queueMaxWidth`, and the chosen value is persisted
    /// with `@SceneStorage` — so this is only the first-launch width.
    static let queueWidth: CGFloat = 280
    static let queueMinWidth: CGFloat = 220
    static let queueMaxWidth: CGFloat = 420
    /// Height of the bottom Now Playing bar (`safeAreaInset(edge: .bottom)`).
    static let nowPlayingHeight: CGFloat = 76
    /// Cover size in a song row.
    static let coverSmall: CGFloat = 56
    /// Cover size in a grid card.
    static let coverCard: CGFloat = 140
    /// Cover size in the Now Playing bar's expanded art.
    static let coverNowPlaying: CGFloat = 300

    static let radius: CGFloat = 12

    static let windowMinSize = CGSize(width: 1100, height: 700)
    static let windowDefaultSize = CGSize(width: 1280, height: 800)
}
