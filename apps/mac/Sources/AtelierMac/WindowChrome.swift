import SwiftUI
import AppKit

/// Make the host NSWindow's titlebar transparent and full-size — so the
/// app's content (gradient + sidebar) extends all the way to the top edge
/// instead of leaving a blank strip above the workspace header.
struct ChromelessWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let w = window else { return }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        // Keep traffic lights visible (default), but the toolbar area is now
        // overlaid on top of content rather than reserving its own band.
    }
}
