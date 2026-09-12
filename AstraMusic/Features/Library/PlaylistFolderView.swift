import SwiftUI

/// The Created / Collected sidebar playlist folders: their kind descriptor and
/// the middle-column grid that renders one of them.

/// The two sidebar playlist folders, backed by the account library.
///
/// `created` maps to owned (or local, before a refresh) lists and `collected`
/// to lists saved from others. These strings are shared by the grid title, the
/// empty state, and the sign-in wall.
enum PlaylistFolderKind {
    case created
    case collected

    var title: String {
        switch self {
        case .created: "Created"
        case .collected: "Collected"
        }
    }

    var emptyTitle: String {
        switch self {
        case .created: "No created playlists"
        case .collected: "No collected playlists"
        }
    }

    var emptySystemImage: String {
        switch self {
        case .created: "square.and.pencil"
        case .collected: "square.stack"
        }
    }
}

/// Middle-column grid for one playlist folder.
///
/// Deliberately mirrors `LibraryView`'s playlist grid: a folder is a top-level
/// route reached from the sidebar, not a Library tab, so it owns its own
/// selection state.
struct PlaylistFolderView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(AuthStore.self) private var auth
    let kind: PlaylistFolderKind
    var onOpenPlaylist: (Playlist) -> Void
    var onPlay: (Song) -> Void

    @State private var playlistSelection: Set<String> = []
    @State private var playlistAnchor: Int?

    /// Source list, in the order used for shift-click ranges.
    private var playlists: [Playlist] {
        switch kind {
        case .created: library.displayedPlaylists
        case .collected: library.displayedCollectedPlaylists
        }
    }

    var body: some View {
        Group {
            if !auth.isLoggedIn {
                SignInWall(
                    title: "Sign in for \(kind.title.lowercased()) playlists",
                    systemImage: kind.emptySystemImage
                )
            } else if playlists.isEmpty {
                ContentUnavailableView(kind.emptyTitle, systemImage: kind.emptySystemImage)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 20) {
                        ForEach(playlists) { playlist in
                            VStack(alignment: .leading, spacing: 8) {
                                CoverTile(
                                    symbol: playlist.artworkSymbol,
                                    template: playlist.artworkTemplate
                                )
                                .overlay {
                                    if playlistSelection.contains(playlist.id) {
                                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                            .strokeBorder(Theme.accent, lineWidth: 2)
                                    }
                                }
                                Text(playlist.name)
                                    .font(.headline)
                                    .lineLimit(1)
                                    .foregroundStyle(.primary)
                                Text(playlist.subtitle)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .frame(width: Theme.coverCard, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                let intent = NSEvent.modifierFlags.rowSelectIntent
                                if intent == .play { onOpenPlaylist(playlist) }
                                RowSelection.apply(
                                    intent, id: playlist.id, order: playlists.map(\.id),
                                    selected: &playlistSelection, anchor: &playlistAnchor
                                )
                            }
                            .contextMenu {
                                // Right-clicking any member of a multi-selection
                                // shows the batch menu; otherwise the single menu.
                                if playlistSelection.count > 1 && playlistSelection.contains(playlist.id) {
                                    PlaylistBatchMenu(
                                        playlists: playlists.filter { playlistSelection.contains($0.id) }
                                    )
                                } else {
                                    PlaylistContextActions(playlist: playlist)
                                }
                            }
                            .focusEffectDisabled()
                        }
                    }
                    .padding(24)
                }
                .hidesScrollIndicators()
            }
        }
        .navigationTitle(kind.title)
        .escClearsSelection(
            isActive: { !playlistSelection.isEmpty },
            clear: {
                playlistSelection = []
                playlistAnchor = nil
            }
        )
    }
}
