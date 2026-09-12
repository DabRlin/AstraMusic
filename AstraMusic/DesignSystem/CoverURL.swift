import Foundation

/// Kugou cover URLs are templates with a `{size}` placeholder.
///
/// Plain static helpers so views can resolve artwork without going through the
/// network layer. Callers should fall back to a symbol tile when `resolve`
/// returns `nil`.
enum CoverURL {
    /// Fills in `{size}` and returns a parsable URL, or `nil` for a missing/blank
    /// template. `http://` is rewritten to `https://` so covers don't depend on
    /// the app's ATS exceptions.
    static func resolve(_ template: String?, pixelSize: Int) -> URL? {
        guard var value = template?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "{size}", with: "\(pixelSize)")
        if value.hasPrefix("http://") {
            value = "https://" + value.dropFirst("http://".count)
        }
        return URL(string: value)
    }

    /// Quantises a layout point size to the pixel size substituted into the
    /// template. The coarse buckets are deliberate: a handful of distinct CDN
    /// URLs keeps the image cache small.
    static func pixelSize(for pointSize: CGFloat) -> Int {
        switch pointSize {
        case ..<48: 100
        case ..<80: 120
        case ..<180: 240
        default: 480
        }
    }
}
