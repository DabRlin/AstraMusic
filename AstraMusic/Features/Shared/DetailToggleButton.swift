/// Home of `DetailToggleButton`, the rounded header toggle used by the artist
/// and playlist detail headers.

import SwiftUI

/// Rounded toggle used by the artist and playlist detail headers. Label and
/// symbol are supplied per entity.
/// Rounded header toggle for artist / playlist detail. The owner supplies the
/// label, symbol, and action so the button stays entity-agnostic.
struct DetailToggleButton: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // Style the symbol explicitly: a `Label` inside a bordered
                // button draws its icon with the system accent color.
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
            }
        }
        .buttonStyle(.bordered)
    }
}
