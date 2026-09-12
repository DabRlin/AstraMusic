import SwiftUI

/// The queue, drawn as a fixed-width column *inside* the detail column rather
/// than a window inspector (toggling an `.inspector` after a resize shoves the
/// sidebar). `ContentView` owns its width and visibility via `@SceneStorage` and
/// overlays the resize handle on this view's leading edge. Reads `PlayerStore` only.
struct QueueView: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Queue")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if player.queue.isEmpty {
                // An empty queue is a normal state, not a failure.
                ContentUnavailableView("Nothing queued", systemImage: "music.note.list")
                    .frame(maxHeight: .infinity)
            } else {
                // The queue can legitimately hold the same song twice, so row
                // identity is index-based (`QueueEntry`) and the current-track
                // highlight compares the index, not the song.
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(queueItems) { item in
                            SongRow(
                                song: item.song,
                                isCurrent: item.index == player.currentIndex
                            ) {
                                player.play(item.song)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .hidesScrollIndicators()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }

    private var queueItems: [QueueEntry] {
        player.queue.enumerated().map { QueueEntry(index: $0.offset, song: $0.element) }
    }
}

/// Pairs a queue element with its position. `Song.id` is not unique within the
/// queue (the same track can be queued more than once), hence the composite id.
private struct QueueEntry: Identifiable {
    let index: Int
    let song: Song
    var id: String { "\(index)-\(song.id)" }
}

/// Invisible grab strip laid over the queue's leading edge by `ContentView`; it
/// takes no layout width, so the queue and detail columns stay flush.
///
/// The width binding is updated on every drag frame for live layout, but
/// `onCommit` fires once on release, so `@SceneStorage` is written once instead
/// of per frame.
struct QueueResizeHandle: View {
    @Binding var width: CGFloat
    var minWidth: CGFloat = Theme.queueMinWidth
    var maxWidth: CGFloat = Theme.queueMaxWidth
    var onCommit: () -> Void = {}

    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 8)
            .overlay(alignment: .leading) {
                Divider()
            }
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            // `.global` keeps the gesture independent of the handle's own
            // position; with the default local space, moving the handle while
            // dragging feeds back into the translation and the width jitters.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        // Capture the width at drag start; deriving it from the
                        // live width would feed the drag back into its own translation.
                        if startWidth == nil {
                            startWidth = width
                        }
                        let next = (startWidth ?? width) - value.translation.width
                        // Dragging left grows the queue, so the translation is
                        // subtracted; clamp to the configured bounds.
                        width = min(maxWidth, max(minWidth, next))
                    }
                    .onEnded { _ in
                        startWidth = nil
                        onCommit()
                    }
            )
    }
}
