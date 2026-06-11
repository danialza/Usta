import SwiftUI
import AppKit
import SwiftTerm
import AtelierProto
import GRPCCore

/// NSViewRepresentable wrapping SwiftTerm.TerminalView.
///
/// Critical perf detail: SwiftTerm's TerminalView is HEAVY — it owns a
/// Metal layer, a font atlas, and a CharData grid. Allocating one per
/// SwiftUI re-mount (role-chip switch) blocked the main thread.
///
/// Now the NSView is owned by TerminalSession (strong ref). makeNSView
/// pops the cached view out of its previous superview and reuses it.
/// The terminal grid, scrollback, and font atlas survive the mount.
struct PtyTerminalView: NSViewRepresentable {
    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: (Data) -> Void = { _ in }
        var onResize: (Int, Int) -> Void = { _, _ in }
        weak var hosted: TerminalView?

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            onInput(Data(data))
        }
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            onResize(newCols, newRows)
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {}
    }

    @ObservedObject var session: TerminalSession

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        // FAST PATH: reuse the cached NSView the session is already
        // streaming bytes into.
        let term: TerminalView
        if let cached = session.cachedView {
            term = cached
            // Detach from previous SwiftUI hosting view so AppKit lets us
            // re-host it under a new parent.
            cached.removeFromSuperview()
        } else {
            term = TerminalView()
            term.terminalDelegate = context.coordinator
            session.attach(view: term)
        }
        context.coordinator.hosted = term
        context.coordinator.onInput = { [weak session] data in
            Task { await session?.sendInput(data) }
        }
        context.coordinator.onResize = { [weak session] cols, rows in
            Task { await session?.sendResize(cols: cols, rows: rows) }
        }
        // Re-bind so the session's flushPending targets the live view.
        session.attach(view: term)
        // Grab keyboard focus ONCE per mount — not on every update.
        DispatchQueue.main.async { [weak term] in
            term?.window?.makeFirstResponder(term)
        }
        return term
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Drain anything that arrived while the view was offscreen.
        session.flushPending(to: nsView)
        // Intentionally NO makeFirstResponder here — repeated calls per
        // SwiftUI body invalidation caused responder churn / lag.
    }
}
