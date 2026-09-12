import SwiftUI

/// Persistent transport strip pinned to the bottom of the detail column.
///
/// `ContentView` installs it as a `safeAreaInset(edge: .bottom)`, so it stays
/// put while the navigation stack scrolls underneath and does not consume
/// content height itself. Talks only to `PlayerStore`.
struct NowPlayingBar: View {
    @Environment(PlayerStore.self) private var player
    var onOpenLyrics: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 16) {
                songInfo
                Spacer(minLength: 8)
                transport
                Spacer(minLength: 8)
                progress
                PlaybackModeButton()
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(minHeight: Theme.nowPlayingHeight)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var songInfo: some View {
        if let song = player.currentSong {
            HStack(spacing: 12) {
                // Artwork doubles as the "open Cover / Lyrics" affordance;
                // `LyricsView` replaces the whole window, it is not a sheet.
                CoverTile(song: song, size: Theme.coverSmall)
                    .help("Show lyrics")
                    .onTapGesture(perform: onOpenLyrics)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // Playback failures (login expired, risk verification, a CDN
                    // refusal) surface here instead of failing silently. Keep the
                    // message visible until the next attempt clears it.
                    if let error = player.playbackError {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .frame(minWidth: 140, maxWidth: 220, alignment: .leading)
            }
        } else {
            Text("Not playing")
                .foregroundStyle(.secondary)
                .frame(minWidth: 140, alignment: .leading)
        }
    }

    private var transport: some View {
        HStack(spacing: 20) {
            Button(action: player.playPrevious) {
                Image(systemName: "backward.fill")
            }
            .disabled(player.queue.isEmpty)
            .help("Previous")

            Button(action: player.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 28)
            }
            .disabled(player.currentSong == nil)
            // Space toggles playback with no modifiers, so it only fires when no
            // text field or other control has focus.
            .keyboardShortcut(.space, modifiers: [])
            .help(player.isPlaying ? "Pause" : "Play")

            Button(action: player.playNext) {
                Image(systemName: "forward.fill")
            }
            .disabled(player.queue.isEmpty)
            .help("Next")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
    }

    private var progress: some View {
        HStack(spacing: 8) {
            Text(player.currentTimeLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            // Two-phase seek: dragging only previews and the real AVPlayer seek
            // happens once on release, so we never seek per frame.
            Slider(
                value: Binding(
                    get: { player.progress },
                    set: { player.previewSeek(progress: $0) }
                ),
                in: 0...1
            ) { editing in
                if !editing {
                    player.commitSeek()
                }
            }
            .controlSize(.small)
            .tint(Theme.accent)
            .frame(minWidth: 140, maxWidth: 260)
            // Duration is unknown while a stream is still resolving; scrubbing
            // then would compute against a zero length.
            .disabled(player.duration <= 0)
            Text(player.durationLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
        }
    }
}
