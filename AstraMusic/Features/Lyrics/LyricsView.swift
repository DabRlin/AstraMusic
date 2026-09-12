import SwiftUI

/// Immersive full-window lyrics view. It replaces the whole window's content
/// (not a sheet or overlay), so `ContentView` toggles the window chrome around
/// it and swaps the split view back in on close.
///
/// Reads everything from `PlayerStore`; seeking and playback control are forwarded
/// to it rather than reimplemented here.
struct LyricsView: View {
    @Environment(PlayerStore.self) private var player
    var onClose: () -> Void

    private var canvas: Color {
        // Hardcoded deep violet rather than a theme color: lyrics are always
        // rendered in a dark scheme, independent of the system appearance.
        Color(red: 0.09, green: 0.06, blue: 0.16)
    }

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
            closeButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(canvas)
        .toolbar(.hidden, for: .windowToolbar)
        // No title bar, no system-resolved colors: the view owns the full
        // window while it is presented.
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onClose)
        // Lets the immersive view take keyboard focus, so its space-bar / Esc
        // shortcuts are handled here rather than by an ancestor.
        .focusable()
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 44, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close lyrics")
        // Above the gradient so it stays legible over any artwork.
        .padding(.top, 6)
        .zIndex(1)
    }

    private var background: some View {
        ZStack {
            canvas
            LinearGradient(
                colors: [
                    Theme.accent.opacity(0.58),
                    Color(red: 0.08, green: 0.05, blue: 0.16),
                    Color.black,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(Theme.accentSoft.opacity(0.28))
                .frame(width: 640, height: 640)
                .blur(radius: 120)
                .offset(x: -240, y: -40)
                // Decorative only; it must never intercept clicks meant for the
                // lyrics or transport controls.
                .allowsHitTesting(false)
        }
        // Reach under the (now transparent) title bar and to all window edges.
        .ignoresSafeArea()
    }

    private var content: some View {
        // Two equal-width columns: artwork + transport on the left, lyrics on
        // the right.
        HStack(spacing: 56) {
            artworkColumn
                .frame(maxWidth: .infinity)
            lyricsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 56)
        .padding(.top, 52)
        .padding(.bottom, 28)
    }

    private var artworkColumn: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            // With no current song the block degrades to a dimmed placeholder
            // cover, so the transport below still has an anchor.
            if let song = player.currentSong {
                CoverTile(song: song, size: Theme.coverNowPlaying)
                    .shadow(color: .black.opacity(0.35), radius: 28, y: 16)
                VStack(spacing: 4) {
                    Text(song.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(song.artistName)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            } else {
                CoverTile(symbol: "music.note", size: Theme.coverNowPlaying)
                    .opacity(0.7)
            }
            transport
            Spacer(minLength: 12)
        }
    }

    private var transport: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text(player.currentTimeLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, alignment: .trailing)
                // Dragging previews locally (`previewSeek`); the seek is only
                // committed when the drag ends, so a drag does not spam the
                // player with seeks.
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
                .tint(.white)
                // Disabled until the duration is known, so the thumb cannot be
                // dragged against a zero range.
                .disabled(player.duration <= 0)
                Text(player.durationLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 36, alignment: .leading)
            }

            HStack(spacing: 28) {
                Button(action: player.playPrevious) {
                    Image(systemName: "backward.fill")
                }
                // Previous / next need a queue; play-pause needs a loaded track.
                .disabled(player.queue.isEmpty)

                Button(action: player.togglePlayPause) {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 32)
                }
                .disabled(player.currentSong == nil)
                .keyboardShortcut(.space, modifiers: [])

                Button(action: player.playNext) {
                    Image(systemName: "forward.fill")
                }
                .disabled(player.queue.isEmpty)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .font(.title3)
        }
        .frame(maxWidth: 360)
    }

    @ViewBuilder
    private var lyricsColumn: some View {
        // Three explicit states; "no lyrics" is distinct from "nothing playing"
        // so an empty lyric file is not mistaken for a stopped player.
        if player.currentSong == nil {
            ContentUnavailableView("Nothing playing", systemImage: "music.note")
                .foregroundStyle(.white.opacity(0.85))
        } else if player.lyrics.isEmpty {
            ContentUnavailableView(
                "No lyrics",
                systemImage: "text.quote",
                description: Text("This track has no lyric file yet.")
            )
            .foregroundStyle(.white.opacity(0.85))
        } else {
            lyricList
        }
    }

    private var lyricList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    // Identity is the line's own id (not the index) so LyricLine
                    // identity stays stable as the highlight moves.
                    ForEach(Array(player.lyrics.enumerated()), id: \.element.id) { index, line in
                        lyricRow(line, index: index)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 80)
                .frame(maxWidth: 520, alignment: .leading)
            }
            .hidesScrollIndicators()
            .onChange(of: player.currentLyricIndex) { previous, index in
                guard let index else { return }
                move(to: index, from: previous, proxy: proxy)
            }
            .onAppear {
                // Land on the current line without an initial scroll animation.
                guard let index = player.currentLyricIndex else { return }
                proxy.scrollTo(player.lyrics[index].id, anchor: .center)
            }
        }
    }

    /// The highlight leads the motion: a line lights up the moment it becomes
    /// current, then the sheet slides it up into the middle a beat later, so the
    /// light is already on the line before it moves.
    private func move(to index: Int, from previous: Int?, proxy: ScrollViewProxy) {
        // Guard against a stale index arriving after lyrics were replaced.
        guard player.lyrics.indices.contains(index) else { return }
        guard let previous, abs(previous - index) == 1 else {
            // First line or a seek: land on it immediately.
            proxy.scrollTo(player.lyrics[index].id, anchor: .center)
            return
        }
        // Delaying the scroll a beat after the highlight flips makes the light
        // read as leading the motion; a short duration keeps it a brisk slide.
        withAnimation(.easeInOut(duration: 0.45).delay(0.1)) {
            proxy.scrollTo(player.lyrics[index].id, anchor: .center)
        }
    }

    /// Rows fade and scale between states instead of snapping, so moving from one
    /// line to the next reads as a transition rather than a jump. Every row keeps
    /// the same base font — the current one is scaled up — which avoids the
    /// layout shifts that made the scroll look jittery.
    private func lyricRow(_ line: LyricLine, index: Int) -> some View {
        let currentIndex = player.currentLyricIndex
        // `distance` drives the fade: the current line is full strength, its
        // neighbours are brighter than the rest, so the eye is led to the line
        // without everything else competing.
        let distance = currentIndex.map { abs($0 - index) } ?? Int.max
        let isCurrent = distance == 0
        let opacity = isCurrent ? 1.0 : (distance == 1 ? 0.55 : 0.32)

        return Button {
            player.seek(to: line.time)
        } label: {
            Text(line.text)
                .font(.title3)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(.white.opacity(opacity))
                .scaleEffect(isCurrent ? 1.08 : 1.0, anchor: .leading)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Seek to this line")
        .animation(.easeInOut(duration: 0.35), value: currentIndex)
    }
}
