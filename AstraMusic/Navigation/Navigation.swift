import Foundation

/// Top-level destinations selectable from the sidebar. Choosing a root clears
/// the detail navigation path, so every root owns its own back stack.
///
/// These are roots only. Drill-down targets live in `Route`; do not merge the two
/// into a single enum — the removed `AppDestination` did, and the sidebar and the
/// navigation stack genuinely need different types.
enum RootSection: Hashable, Identifiable {
    // Recommend group: discovery, search, and the library hub.
    case forYou
    case search
    case library

    // My music: the signed-in account's content. Liked Songs is a fixed view, not
    // a deletable playlist.
    case likedSongs
    case albums
    case artists
    case recent

    // Playlists: Created and Collected only — there is no "New Playlist" root yet.
    case createdPlaylists
    case collectedPlaylists

    /// Identity for sidebar selection / `Identifiable`; unrelated to any Kugou id.
    var id: String {
        switch self {
        case .forYou: "forYou"
        case .search: "search"
        case .library: "library"
        case .likedSongs: "likedSongs"
        case .albums: "albums"
        case .artists: "artists"
        case .recent: "recent"
        case .createdPlaylists: "createdPlaylists"
        case .collectedPlaylists: "collectedPlaylists"
        }
    }

    /// Sidebar row label.
    var title: String {
        switch self {
        case .forYou: "For you"
        case .search: "Search"
        case .library: "Library"
        case .likedSongs: "Liked Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .recent: "Recent"
        case .createdPlaylists: "Created"
        case .collectedPlaylists: "Collected"
        }
    }

    /// SF Symbol shown next to the label.
    var systemImage: String {
        switch self {
        case .forYou: "sparkles"
        case .search: "magnifyingglass"
        case .library: "square.stack"
        case .likedSongs: "heart.fill"
        case .albums: "square.stack.fill"
        case .artists: "person.2"
        case .recent: "clock"
        case .createdPlaylists: "square.and.pencil"
        case .collectedPlaylists: "music.note.list"
        }
    }
}

/// A drill-down destination pushed onto the detail column's navigation stack.
/// The object is carried directly, so results that are not in the library
/// (search, recommended playlists) render without a side channel.
///
/// `Hashable` is what lets `ContentView` keep the stack as a plain `[Route]`;
/// opening an item appends, Esc pops one.
enum Route: Hashable {
    case playlist(Playlist)
    case album(Album)
    case artist(Artist)
}
