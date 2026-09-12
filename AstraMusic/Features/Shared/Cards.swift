/// Home of `SongCard`, the fixed-width play card used by card grids.

import SwiftUI

/// Fixed-width play card (cover + title + artist) used in grids. The whole card
/// is a single plain button; the context menu is attached by
/// `songLibraryActions`.
struct SongCard: View {
    let song: Song
    var onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                CoverTile(song: song)
                Text(song.title)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(song.artistName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Theme.coverCard, alignment: .leading)
        }
        .buttonStyle(.plain)
        .songLibraryActions(song)
    }
}
