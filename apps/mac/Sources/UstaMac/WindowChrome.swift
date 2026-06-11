import SwiftUI
import AppKit

/// Make host NSWindow titlebar transparent + full-size. Configures the
/// window ONCE per attach; updateNSView is a no-op so app-focus changes
/// don't pile up DispatchQueue work.
struct ChromelessWindow: NSViewRepresentable {
    final class Coordinator {
        var didConfigure = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [weak v] in
            guard let w = v?.window, !context.coordinator.didConfigure else { return }
            context.coordinator.didConfigure = true
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        // intentionally empty — config is one-shot
    }
}
