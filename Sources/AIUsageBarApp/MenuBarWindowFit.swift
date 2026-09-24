import AppKit
import SwiftUI

/// Keeps the `MenuBarExtra(.window)` panel sized to its content.
///
/// SwiftUI sizes that panel when it opens but does not shrink it when the
/// content later gets shorter (a refresh clearing wrapped stale messages, a
/// window row disappearing), so the panel keeps its old height and shows an
/// empty band between the menu bar and the dropdown. This measures the
/// content and resizes the hosting window to match, keeping its top edge
/// pinned under the status item.
struct MenuBarWindowFit: ViewModifier {
    @State private var window: NSWindow?
    @State private var contentHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .background(WindowReader { window = $0 })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = height
                fit()
            }
            .onChange(of: window) {
                fit()
            }
    }

    private func fit() {
        guard let window, let contentHeight else { return }
        let current = window.contentRect(forFrameRect: window.frame)
        guard let fitted = Self.contentRect(fitting: contentHeight, in: current) else { return }
        window.setFrame(window.frameRect(forContentRect: fitted), display: true)
    }

    /// The content rect that holds `height` with the top edge unchanged, or
    /// `nil` when `current` already fits (AppKit's origin is bottom-left, so
    /// a plain `setContentSize` would pin the bottom edge instead).
    nonisolated static func contentRect(fitting height: CGFloat, in current: NSRect) -> NSRect? {
        guard abs(current.height - height) >= 0.5 else { return nil }
        return NSRect(
            x: current.minX,
            y: current.maxY - height,
            width: current.width,
            height: height
        )
    }
}

/// Reports the window hosting this view whenever it moves between windows.
private struct WindowReader: NSViewRepresentable {
    let onWindowChange: @MainActor (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReportingView {
        let view = ReportingView()
        view.onWindowChange = onWindowChange
        return view
    }

    func updateNSView(_ view: ReportingView, context: Context) {
        view.onWindowChange = onWindowChange
    }

    final class ReportingView: NSView {
        var onWindowChange: (@MainActor (NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}
