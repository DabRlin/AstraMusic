import SwiftUI

/// Left column of the split view: the app's root-level destinations only.
///
/// Rows are `RootSection` cases tagged onto the `List` selection; picking one
/// swaps the middle column's root and clears its drill-down path (done by
/// `ContentView`), so each root owns its own back stack. Individual playlists
/// are never sidebar rows.
struct SidebarView: View {
    @Environment(LibraryStore.self) private var library
    @Binding var section: RootSection
    var onOpenPinnedPlaylist: (Playlist) -> Void = { _ in }

    var body: some View {
        List(selection: $section) {
            Section("Recommend") {
                sidebarRow(.forYou)
                sidebarRow(.search)
                sidebarRow(.library)
            }

            Section("My music") {
                sidebarRow(.likedSongs)
                sidebarRow(.albums)
                sidebarRow(.artists)
                sidebarRow(.recent)
            }

            Section("Playlists") {
                sidebarRow(.createdPlaylists)
                sidebarRow(.collectedPlaylists)
            }

            // Pinned playlists are shortcuts, not roots: they push a `.playlist`
            // route through the callback and stay untagged, so they never take
            // over the sidebar selection. The whole section disappears when empty.
            if !library.pinnedPlaylists.isEmpty {
                Section("Pinned") {
                    ForEach(library.pinnedPlaylists) { playlist in
                        Button {
                            onOpenPinnedPlaylist(playlist)
                        } label: {
                            Label(playlist.name, systemImage: "pin.fill")
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                library.togglePinned(playlist)
                            } label: {
                                Label("Unpin from Sidebar", systemImage: "pin.slash")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // SwiftUI's own scroll-indicator flag does not reach the sidebar's
        // backing NSScrollView; see `ScrollIndicators.swift` for the AppKit part.
        .hidesScrollIndicators()
        // Sidebar stays at its designed width (280 is the drag ceiling), which is
        // why the window's resizing pressure goes to the detail column instead.
        .navigationSplitViewColumnWidth(min: Theme.sidebarWidth, ideal: Theme.sidebarWidth, max: 280)
    }

    /// The `.tag` is what makes the row selectable by `List(selection:)`, so it
    /// must stay the `RootSection` value itself, not a string id.
    private func sidebarRow(_ item: RootSection) -> some View {
        Label(item.title, systemImage: item.systemImage)
            .tag(item)
    }
}
