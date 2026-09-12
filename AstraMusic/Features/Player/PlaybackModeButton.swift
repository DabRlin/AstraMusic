import SwiftUI

/// Compact button that cycles the queue's playback mode in `allCases` order.
///
/// Cycling is local queue behaviour (no Kugou call); `PlayerStore.setPlaybackMode`
/// is what persists the new value. Icon, tooltip, and accessibility label all
/// read from the current mode so they can never disagree with it.
struct PlaybackModeButton: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        Button(action: cycleMode) {
            Image(systemName: player.playbackMode.icon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(player.playbackMode.title)
        .accessibilityLabel(player.playbackMode.title)
    }

    private func cycleMode() {
        // Wraps last → first via the modulo; the guard is only a safety net since
        // the current mode is always one of `allCases`.
        let modes = PlaybackMode.allCases
        guard let index = modes.firstIndex(of: player.playbackMode) else { return }
        let next = modes[(index + 1) % modes.count]
        player.setPlaybackMode(next)
    }
}
