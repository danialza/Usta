import Foundation
import SwiftUI
import AtelierProto
import SwiftTerm
import GRPCCore
import GRPCNIOTransportHTTP2

/// Drives one bidirectional StreamPty RPC. Bytes from the server are pushed
/// into the bound SwiftTerm view; input from the view is forwarded to the
/// server via an AsyncStream we control.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id: String
    let title: String
    var roleName: String? = nil
    var roleEmoji: String? = nil

    @Published var alive: Bool = true
    @Published var lastError: String? = nil

    private weak var bound: TerminalView?
    private var pendingBytes: [UInt8] = []

    private var outboundContinuation: AsyncStream<Atelier_V1_PtyClientMsg>.Continuation?
    private var rpcTask: Task<Void, Never>?

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    func attach(view: TerminalView) {
        self.bound = view
        flushPending(to: view)
    }

    func flushPending(to view: TerminalView) {
        guard !pendingBytes.isEmpty else { return }
        view.feed(byteArray: ArraySlice(pendingBytes))
        pendingBytes.removeAll(keepingCapacity: true)
    }

    /// Start the bidirectional RPC.
    func start(stub: Atelier_V1_Atelier.Client<HTTP2ClientTransport.Posix>) {
        let id = self.id
        let (stream, cont) = AsyncStream<Atelier_V1_PtyClientMsg>.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.outboundContinuation = cont

        var attachMsg = Atelier_V1_PtyClientMsg()
        attachMsg.attach = .with { $0.terminalID = id }
        cont.yield(attachMsg)

        var resizeMsg = Atelier_V1_PtyClientMsg()
        resizeMsg.resize = .with { $0.cols = 120; $0.rows = 32 }
        cont.yield(resizeMsg)

        rpcTask?.cancel()
        let weakSelf = WeakSession(value: self)
        rpcTask = Task {
            do {
                try await stub.streamPty(
                    requestProducer: { writer in
                        for await msg in stream {
                            try await writer.write(msg)
                        }
                    },
                    onResponse: { response in
                        for try await server in response.messages {
                            if let s = weakSelf.value {
                                await s.handleServer(server)
                            }
                        }
                    }
                )
            } catch {
                if let s = weakSelf.value {
                    await MainActor.run {
                        s.lastError = "pty: \(error)"
                        s.alive = false
                    }
                }
            }
        }
    }

    func stop() {
        outboundContinuation?.finish()
        rpcTask?.cancel()
        alive = false
    }

    /// Cap on bytes buffered while no SwiftTerm view is bound. Without
    /// this, an offscreen pane (role chip focus) leaks unbounded — claude
    /// keeps streaming and we keep appending forever. 256KB ≈ ~3K lines
    /// of output, plenty for catch-up when user comes back.
    private static let pendingBytesCap = 256 * 1024

    private func handleServer(_ msg: Atelier_V1_PtyServerMsg) {
        switch msg.kind {
        case .output(let o):
            let bytes = [UInt8](o.data)
            if let v = bound {
                v.feed(byteArray: ArraySlice(bytes))
            } else {
                pendingBytes.append(contentsOf: bytes)
                if pendingBytes.count > Self.pendingBytesCap {
                    // Drop oldest half — keep most recent.
                    let drop = pendingBytes.count - Self.pendingBytesCap
                    pendingBytes.removeFirst(drop)
                }
            }
        case .exit(let e):
            self.lastError = "exit: \(e.reason)"
            self.alive = false
        case .error(let e):
            self.lastError = e.message
        case .none:
            break
        }
    }

    func sendInput(_ data: Data) async {
        var msg = Atelier_V1_PtyClientMsg()
        msg.input = .with { $0.data = data }
        outboundContinuation?.yield(msg)
    }

    func sendResize(cols: Int, rows: Int) async {
        var msg = Atelier_V1_PtyClientMsg()
        msg.resize = .with { $0.cols = Int32(cols); $0.rows = Int32(rows) }
        outboundContinuation?.yield(msg)
    }
}

/// Small Sendable wrapper around a weak TerminalSession reference so the
/// gRPC stream closures (which require @Sendable) can safely look up the
/// owning actor.
struct WeakSession: @unchecked Sendable {
    weak var value: TerminalSession?
}
