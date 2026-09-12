/// Home of `SongRow` and the shared Notes-style multi-select types it drives:
/// `RowSelectIntent`, `RowSelection`, and `SongRowSelection`.

import AppKit
import SwiftUI

/// Outset (in points) for the multi-select ring so it lines up with the
/// system's right-click highlight, which is drawn slightly outside the row's
/// bounds. Tune this single number to align the two frames.
private let selectionRingOutset: CGFloat = 4

/// How a click on a selectable row behaves (macOS Notes-style multi-select).
enum RowSelectIntent {
    case play          // plain click: perform the row's action, clear selection
    case toggle        // ⌘-click: add/remove this row from the selection
    case extend        // shift-click: select the range from the anchor row
}

extension NSEvent.ModifierFlags {
    /// Maps the pressed modifiers to the row-click intent: plain = play,
    /// ⌘ = toggle, shift = extend range.
    var rowSelectIntent: RowSelectIntent {
        if contains(.command) { return .toggle }
        if contains(.shift) { return .extend }
        return .play
    }
}

/// Core multi-select state machine shared by song rows, playlist tiles, and
/// album rows. `order` is the visible list order so shift-click can extend a
/// contiguous range.
enum RowSelection {
    static func apply(
        _ intent: RowSelectIntent,
        id: String,
        order: [String],
        selected: inout Set<String>,
        anchor: inout Int?
    ) {
        guard let index = order.firstIndex(of: id) else { return }
        switch intent {
        case .play:
            // A plain click both plays and drops the selection, so a single
            // click never leaves rows silently selected.
            if !selected.isEmpty { selected = [] }
            anchor = nil
        case .toggle:
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
            // The clicked row becomes the anchor for a following shift-click.
            anchor = index
        case .extend:
            let base = anchor ?? index
            let range = min(base, index)...max(base, index)
            var next: Set<String> = []
            for i in range { next.insert(order[i]) }
            selected = next
            // Keep the original anchor (not the clicked end) so repeated
            // shift-clicks grow and shrink the range from the same origin.
            anchor = base
        }
    }
}

/// Bundle a song row's multi-select state for rendering and menus.
struct SongRowSelection {
    let isSelected: Bool
    let isBatch: Bool          // part of a multi-selection → batch menu
    let selectedSongs: [Song]  // the selected songs, in list order
    /// Set when the selection lives inside a playlist, so the batch menu can
    /// offer "Remove from Playlist".
    var removeFrom: Playlist? = nil
    /// Reports the click intent back to the owner, which owns `selected` and the
    /// anchor index.
    let onIntent: (RowSelectIntent) -> Void
}

/// One song row: cover, title/artist, optional like button, duration.
///
/// Plays on plain tap; when `selection` is provided the row becomes a
/// Notes-style multi-select target (⌘ toggles, shift extends). Like state is
/// read straight from `LibraryStore` — the row never holds `AuthStore`.
struct SongRow: View {
    let song: Song
    var isCurrent: Bool = false
    var removeFrom: Playlist? = nil
    /// When set, the row joins Notes-style multi-select: shift/⌘-clicks adjust
    /// the selection instead of playing, and the context menu switches to the
    /// batch variant.
    var selection: SongRowSelection? = nil
    /// In Liked Songs, unliking removes the row from the list, so the toggle is
    /// shown at the bottom of the context menu like a remove action.
    var inLikedCollection: Bool = false
    var onPlay: () -> Void

    @Environment(LibraryStore.self) private var library
    @State private var isHovering = false

    var body: some View {
        let liked = library.isLiked(song)
        HStack(spacing: 12) {
            CoverTile(song: song, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            // Guests get no like affordance at all (likes require an account);
            // a liked song keeps its heart visible so unlike is discoverable
            // without hovering first.
            if library.currentUserID != nil, isHovering || liked {
                Button {
                    library.requestToggleLike(song)
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(liked ? "Unlike" : "Like")
            }

            Text(song.durationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(4)
        // The whole row plays, not just the title. The like button above is a
        // real Button, so it still takes its own taps.
        .contentShape(Rectangle())
        .overlay {
            // Drawn as an overlay, so the ring adds no layout width; the negative
            // padding pushes it outside the row to line up with the system
            // right-click highlight.
            if selection?.isSelected == true {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 1.5)
                    .padding(-selectionRingOutset)
            }
        }
        .onTapGesture {
            if let selection {
                let intent = NSEvent.modifierFlags.rowSelectIntent
                // Only a plain click plays; ⌘/shift clicks just adjust the
                // selection. The owner is told about every click either way.
                if intent == .play { onPlay() }
                selection.onIntent(intent)
            } else {
                onPlay()
            }
        }
        .onHover { isHovering = $0 }
        .songLibraryActions(
            song,
            removeFrom: removeFrom,
            selection: selection,
            inLikedCollection: inLikedCollection
        )
        .tint(Theme.accent)
        // The right-click menu source draws a system ring; suppress focus
        // effects so the purple selection border is the only outline.
        .focusEffectDisabled()
    }
}
