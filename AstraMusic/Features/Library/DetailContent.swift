import SwiftUI

/// The loading / message / empty / content ladder shared by the detail screens
/// (playlist, album, artist).
///
/// Renders exactly one of: a spinner, an inline message, the `empty` view, or
/// `content`. The first three only apply while `isEmpty` is true, so a failed
/// refresh never hides content that already loaded. `isCentered` adds the
/// vertical spring the artist screen wants for its non-content states, which sit
/// in a plain `VStack` rather than inside a `List`.
struct DetailContent<Content: View, Empty: View>: View {
    private let isEmpty: Bool
    private let isLoading: Bool
    private let message: String?
    private let isCentered: Bool
    private let empty: () -> Empty
    private let content: () -> Content

    init(
        isEmpty: Bool,
        isLoading: Bool = false,
        message: String? = nil,
        isCentered: Bool = false,
        @ViewBuilder empty: @escaping () -> Empty,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isEmpty = isEmpty
        self.isLoading = isLoading
        self.message = message
        self.isCentered = isCentered
        self.empty = empty
        self.content = content
    }

    var body: some View {
        if isLoading, isEmpty {
            centered(ProgressView().controlSize(.small))
        } else if let message, isEmpty {
            centered(Text(message).foregroundStyle(.secondary))
        } else if isEmpty {
            empty()
        } else {
            content()
        }
    }

    @ViewBuilder
    private func centered<V: View>(_ view: V) -> some View {
        if isCentered {
            view.frame(maxHeight: .infinity)
        } else {
            view
        }
    }
}

extension DetailContent where Empty == EmptyView {
    /// Convenience for screens with no dedicated empty state (album): an empty
    /// list simply renders nothing.
    init(
        isEmpty: Bool,
        isLoading: Bool = false,
        message: String? = nil,
        isCentered: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            isEmpty: isEmpty,
            isLoading: isLoading,
            message: message,
            isCentered: isCentered,
            empty: { EmptyView() },
            content: content
        )
    }
}
