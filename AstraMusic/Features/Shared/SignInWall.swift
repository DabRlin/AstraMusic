import SwiftUI

/// Clean logged-out placeholder. No local library, search, or For you content behind it.
///
/// Gated screens render this instead of their real body, so nothing private can
/// leak while signed out.
struct SignInWall: View {
    /// Headline, e.g. "Sign in to search".
    var title: String
    var systemImage: String = "person.crop.circle"
    /// Which feature is behind the wall; defaults to the generic message.
    var description: String = "Sign in with Kugou to use AstraMusic."

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(description)
        )
        // Fill the detail area so the placeholder centers regardless of the
        // column's height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
