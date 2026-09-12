import SwiftUI

/// A `DetailContent` specialised for song rows: it renders one `row` per song
/// and delegates the loading / message / empty ladder to `DetailContent`.
///
/// The caller supplies the `SongRow` configuration because it differs per screen
/// (multi-select, remove-from-playlist, in-liked-collection).
struct TrackListView<Row: View, Empty: View>: View {
    private let songs: [Song]
    private let isLoading: Bool
    private let message: String?
    private let isCentered: Bool
    private let empty: () -> Empty
    private let row: (Song) -> Row

    init(
        songs: [Song],
        isLoading: Bool = false,
        message: String? = nil,
        isCentered: Bool = false,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder row: @escaping (Song) -> Row
    ) {
        self.songs = songs
        self.isLoading = isLoading
        self.message = message
        self.isCentered = isCentered
        self.empty = empty
        self.row = row
    }

    var body: some View {
        DetailContent(
            isEmpty: songs.isEmpty,
            isLoading: isLoading,
            message: message,
            isCentered: isCentered,
            empty: empty
        ) {
            ForEach(songs) { song in
                row(song)
            }
        }
    }
}

extension TrackListView where Empty == EmptyView {
    /// Convenience for screens with no dedicated empty state.
    init(
        songs: [Song],
        isLoading: Bool = false,
        message: String? = nil,
        isCentered: Bool = false,
        @ViewBuilder row: @escaping (Song) -> Row
    ) {
        self.init(
            songs: songs,
            isLoading: isLoading,
            message: message,
            isCentered: isCentered,
            empty: { EmptyView() },
            row: row
        )
    }
}
