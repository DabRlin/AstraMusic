/// Home of the Escape-key monitor that clears an active multi-selection before
/// navigation pops a route (`EscClearsSelectionModifier` + its View extension).

import AppKit
import SwiftUI

/// Esc clears an active Notes-style multi-selection before the window's
/// navigation handler pops the route. A local key monitor is used because the
/// list itself may not hold keyboard focus.
///
/// `install` / `uninstall` are paired on appear / disappear; the monitor must
/// always be removed or it keeps intercepting Escape after the view is gone.
private struct EscClearsSelectionModifier: ViewModifier {
    let isActive: () -> Bool
    let clear: () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: install)
            .onDisappear(perform: uninstall)
    }

    private func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 53 is the Escape key code.
            guard event.keyCode == 53, isActive() else { return event }
            clear()
            // Consume the event so it does not also reach the window's
            // Esc-to-step-back handler.
            return nil
        }
    }

    private func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

extension View {
    /// While any row is selected, Escape clears the multi-selection instead of
    /// popping navigation; with nothing selected the event passes through to
    /// the existing Esc-to-step-back handler.
    func escClearsSelection(isActive: @escaping () -> Bool, clear: @escaping () -> Void) -> some View {
        modifier(EscClearsSelectionModifier(isActive: isActive, clear: clear))
    }
}
