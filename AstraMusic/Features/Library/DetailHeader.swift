import SwiftUI

/// The artwork + title + subtitle + Play header shared by the detail screens.
///
/// `cover` and `actions` are slots: the caller supplies the artwork (a song /
/// playlist template, an album, or an artist) and whatever buttons are
/// kind-specific (Collect, Pin, Follow, Rename/Delete). Play is only offered
/// while there is something to play. The caller adds its own horizontal padding
/// (a `List` row supplies it via insets; the artist screen sets 20).
struct DetailHeader<Cover: View, Actions: View>: View {
    private let title: String
    private let subtitle: String?
    private let canPlay: Bool
    private let onPlay: () -> Void
    private let cover: () -> Cover
    private let actions: () -> Actions

    init(
        title: String,
        subtitle: String? = nil,
        canPlay: Bool,
        onPlay: @escaping () -> Void,
        @ViewBuilder cover: @escaping () -> Cover,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.canPlay = canPlay
        self.onPlay = onPlay
        self.cover = cover
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 16) {
            cover()
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    if canPlay {
                        Button("Play", action: onPlay)
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.accent)
                    }
                    actions()
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

extension DetailHeader where Actions == EmptyView {
    /// Convenience for screens with no extra header actions (album).
    init(
        title: String,
        subtitle: String? = nil,
        canPlay: Bool,
        onPlay: @escaping () -> Void,
        @ViewBuilder cover: @escaping () -> Cover
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            canPlay: canPlay,
            onPlay: onPlay,
            cover: cover,
            actions: { EmptyView() }
        )
    }
}
