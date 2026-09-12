/// Home of `CoverTile`, the square cover-art tile shared by rows, cards, detail
/// headers, and the lyrics view.
///
/// A Kugou cover template is resolved through `CoverURL`; when it is missing or
/// fails to resolve, the tile falls back to a gradient with a symbol.

import SwiftUI

/// Square cover-art tile shared by rows, cards, and the lyrics view.
///
/// `template` is a Kugou cover template (possibly containing `{size}`) and goes
/// through `CoverURL`; when it is `nil` or fails to resolve, the tile falls back
/// to a gradient with `symbol`. The convenience initializers exist so callers
/// can pass a `Song` / `Album` / `Artist` without unpacking its artwork fields.
struct CoverTile: View {
    var symbol: String = "music.note"
    var template: String? = nil
    var size: CGFloat = Theme.coverCard

    init(symbol: String = "music.note", template: String? = nil, size: CGFloat = Theme.coverCard) {
        self.symbol = symbol
        self.template = template
        self.size = size
    }

    init(song: Song, size: CGFloat = Theme.coverCard) {
        self.init(symbol: song.artworkSymbol, template: song.artworkTemplate, size: size)
    }

    init(album: Album, size: CGFloat = Theme.coverCard) {
        self.init(symbol: album.artworkSymbol, template: album.artworkTemplate, size: size)
    }

    init(artist: Artist, size: CGFloat = Theme.coverCard) {
        self.init(symbol: artist.artworkSymbol, template: artist.artworkTemplate, size: size)
    }

    var body: some View {
        Group {
            if let url = CoverURL.resolve(template, pixelSize: CoverURL.pixelSize(for: size)) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    case .empty:
                        placeholder
                            .overlay {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        // A successful image is `scaledToFill` and therefore larger than the
        // frame, so the clip below is load-bearing, not cosmetic.
        .frame(width: size, height: size)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    /// Gradient stand-in shown while loading, on failure, or when there is no
    /// template at all.
    private var placeholder: some View {
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Theme.accent.opacity(0.85), Theme.accentSoft.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.32, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            }
    }
}
