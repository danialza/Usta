import Foundation
import SwiftUI
import AtelierProto
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// Observable model holding a long-lived gRPC connection to atelierd over UDS.
@MainActor
final class AtelierClientModel: ObservableObject {
    @Published var connected: Bool = false
    @Published var daemonVersion: String? = nil
    @Published var workspaces: [Atelier_V1_Workspace] = []
    @Published var lastError: String? = nil

    private var runTask: Task<Void, Never>? = nil
    private var stub: Atelier_V1_Atelier.Client<HTTP2ClientTransport.Posix>? = nil

    let socketPath: String = {
        if let s = ProcessInfo.processInfo.environment["ATELIER_SOCKET"], !s.isEmpty { return s }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmp as NSString).appendingPathComponent("atelier.sock")
    }()

    func ensureConnected() async {
        if connected { return }
        await connect()
    }

    func connect() async {
        do {
            let transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext
            )
            let client = GRPCClient(transport: transport)
            let stub = Atelier_V1_Atelier.Client(wrapping: client)

            runTask?.cancel()
            runTask = Task {
                try? await client.runConnections()
            }
            self.stub = stub

            let ping = Atelier_V1_PingRequest.with { $0.clientName = "AtelierMac" }
            let resp = try await stub.ping(ping)
            self.daemonVersion = resp.daemonVersion
            self.connected = true
            self.lastError = nil
            await refreshWorkspaces()
        } catch {
            self.connected = false
            self.lastError = "connect: \(error)"
        }
    }

    func refreshWorkspaces() async {
        guard let stub else { return }
        do {
            let list = try await stub.listWorkspaces(Atelier_V1_Empty())
            self.workspaces = list.items
        } catch {
            self.lastError = "list: \(error)"
        }
    }

    func openWorkspace(path: String) async {
        if !connected { await connect() }
        guard let stub else { return }
        do {
            let req = Atelier_V1_OpenWorkspaceRequest.with { $0.path = path }
            _ = try await stub.openWorkspace(req)
            await refreshWorkspaces()
        } catch {
            self.lastError = "open: \(error)"
        }
    }
}
