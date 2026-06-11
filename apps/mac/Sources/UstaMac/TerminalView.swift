import SwiftUI
import AppKit
import SwiftTerm
import UstaProto
import GRPCCore

/// NSViewRepresentable wrapping SwiftTerm.TerminalView.
/// Bytes coming back from the daemon are fed via `feed(bytes:)`.
/// Keystrokes typed by the user are forwarded via the `onInput` callback.
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
        let term = TerminalView()
        term.terminalDelegate = context.coordinator
        context.coordinator.hosted = term
        context.coordinator.onInput = { [weak session] data in
            Task { await session?.sendInput(data) }
        }
        context.coordinator.onResize = { [weak session] cols, rows in
            Task { await session?.sendResize(cols: cols, rows: rows) }
        }
        session.attach(view: term)
        // Grab keyboard focus ONCE per mount (not on every update).
        DispatchQueue.main.async { [weak term] in
            term?.window?.makeFirstResponder(term)
        }
        return term
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // Drain anything buffered while the view was offscreen.
        session.flushPending(to: nsView)
        // Deliberately NO makeFirstResponder here — repeated calls per
        // SwiftUI body invalidation caused responder churn / lag.
    }
}
