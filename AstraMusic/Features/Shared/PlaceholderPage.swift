/// Home of `PlaceholderPage`, the empty-state page shown when a section has no
/// data yet.

import SwiftUI

/// Empty-state page for sections that have no data yet; it also sets the window
/// navigation title.
struct PlaceholderPage: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}
