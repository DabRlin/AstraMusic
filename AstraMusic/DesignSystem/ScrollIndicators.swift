import AppKit
import SwiftUI

extension View {
    /// Removes the scrolling indicators from this view and the rest of its window.
    ///
    /// `scrollIndicators(.hidden)` often does not reach the `NSScrollView` that
    /// backs a macOS `List`, so its overlay scroller still flashes in while the
    /// user scrolls. This drops down to AppKit and clears
    /// `hasVerticalScroller` / `hasHorizontalScroller` on every scroll view in
    /// the window. Trackpad and wheel scrolling keep working — only the bars go
    /// away.
    func hidesScrollIndicators() -> some View {
        scrollIndicators(.never)
            .background(ScrollIndicatorSuppressor())
    }
}

/// Zero-size probe that switches off AppKit scrollers once it is in a window.
private struct ScrollIndicatorSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.scheduleSuppression()
    }

    final class ProbeView: NSView {
        private var isScheduled = false

        // Two entry points because either can happen first: SwiftUI may lay the
        // probe out before it joins a window, or attach it to one already laid out.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSuppression()
        }

        override func layout() {
            super.layout()
            scheduleSuppression()
        }

        /// Coalesces the layout passes SwiftUI performs into one sweep per run
        /// loop, deferred so the backing scroll views already exist.
        func scheduleSuppression() {
            guard !isScheduled else { return }
            isScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.isScheduled = false
                self?.suppressScrollers()
            }
        }

        private func suppressScrollers() {
            guard let root = window?.contentView else { return }
            // Walk the whole window, not just the probe's subtree: the offending
            // NSScrollView is not a descendant of this zero-size probe.
            func sweep(_ view: NSView) {
                if let scrollView = view as? NSScrollView {
                    if scrollView.hasVerticalScroller { scrollView.hasVerticalScroller = false }
                    if scrollView.hasHorizontalScroller { scrollView.hasHorizontalScroller = false }
                    // Keep a re-enabled scroller from reserving layout space.
                    if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
                }
                for subview in view.subviews { sweep(subview) }
            }
            sweep(root)
        }
    }
}
