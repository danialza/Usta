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

    private(set) var socketPath: String = {
        if let s = ProcessInfo.processInfo.environment["ATELIER_SOCKET"], !s.isEmpty { return s }
        let tmp = ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"
        return (tmp as NSString).appendingPathComponent("atelier.sock")
    }()

    func applySocket(_ path: String) {
        if !path.isEmpty { self.socketPath = path }
    }

    func ensureConnected() async {
        if connected { return }
        await connect()
    }

    func connect() async {
        do {
            // grpc-swift derives ":authority" from the target; for UDS that
            // becomes a URL-encoded path that tonic's h2 parser rejects as
            // "malformed authority". Pin it to "localhost".
            var config = HTTP2ClientTransport.Posix.Config.defaults
            config.http2.authority = "localhost"
            let transport = try HTTP2ClientTransport.Posix(
                target: .unixDomainSocket(path: socketPath),
                transportSecurity: .plaintext,
                config: config
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

    // --- Terminals ---

    func listTerminals(workspaceID: String) async -> [Atelier_V1_Terminal] {
        guard let stub else { return [] }
        do {
            let r = try await stub.listTerminals(.with { $0.workspaceID = workspaceID })
            return r.items
        } catch {
            self.lastError = "list terminals: \(error)"
            return []
        }
    }

    func createTerminal(workspaceID: String, cols: Int = 120, rows: Int = 32) async -> Atelier_V1_Terminal? {
        guard let stub else { return nil }
        do {
            let req = Atelier_V1_CreateTerminalRequest.with {
                $0.workspaceID = workspaceID
                $0.cols = Int32(cols)
                $0.rows = Int32(rows)
            }
            return try await stub.createTerminal(req)
        } catch {
            self.lastError = "create terminal: \(error)"
            return nil
        }
    }

    func closeTerminal(id: String) async {
        guard let stub else { return }
        _ = try? await stub.closeTerminal(.with { $0.id = id })
    }

    /// Returns the underlying stub so a TerminalSession can open a bidi RPC.
    func ptyStub() -> Atelier_V1_Atelier.Client<HTTP2ClientTransport.Posix>? { stub }

    // --- Providers / Roles ---

    func listProviders() async -> [Atelier_V1_ProviderInfo] {
        guard let stub else { return [] }
        do {
            let r = try await stub.listProviders(Atelier_V1_Empty())
            return r.items
        } catch {
            self.lastError = "providers: \(error)"
            return []
        }
    }

    func listRoles(workspaceID: String) async -> [Atelier_V1_Role] {
        guard let stub else { return [] }
        do {
            let r = try await stub.listRoles(.with { $0.workspaceID = workspaceID })
            return r.items
        } catch {
            self.lastError = "roles: \(error)"
            return []
        }
    }

    /// Streaming chat helper. Yields the running text + a final stop_reason.
    func roleChat(
        roleName: String,
        userMsg: String,
        workspaceID: String,
        provider: String,
        model: String,
        onToken: @escaping @MainActor (String) -> Void,
        onTool: @escaping @MainActor (_ name: String, _ input: String, _ output: String, _ isResult: Bool) -> Void,
        onDone: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        guard let stub else { onError("not connected"); return }
        let onTokenSendable = MainActorClosure(closure: onToken)
        let onToolSendable = MainActorToolClosure(closure: onTool)
        let onDoneSendable = MainActorClosure(closure: onDone)
        let onErrorSendable = MainActorClosure(closure: onError)
        Task.detached {
            do {
                let req = Atelier_V1_RoleChatRequest.with {
                    $0.roleName = roleName
                    $0.userMsg = userMsg
                    $0.workspaceID = workspaceID
                    $0.provider = provider
                    $0.model = model
                    $0.maxTokens = 2048
                }
                try await stub.roleChat(req) { response in
                    for try await tok in response.messages {
                        if !tok.error.isEmpty {
                            let msg = tok.error
                            await MainActor.run { onErrorSendable.closure(msg) }
                            return
                        }
                        if !tok.toolName.isEmpty {
                            let (n, i, o, r) = (tok.toolName, tok.toolInput, tok.toolOutput, tok.toolResult)
                            await MainActor.run { onToolSendable.closure(n, i, o, r) }
                        } else if !tok.text.isEmpty {
                            let t = tok.text
                            await MainActor.run { onTokenSendable.closure(t) }
                        }
                        if tok.done {
                            let r = tok.stopReason
                            await MainActor.run { onDoneSendable.closure(r) }
                            return
                        }
                    }
                }
            } catch {
                let s = "\(error)"
                await MainActor.run { onErrorSendable.closure(s) }
            }
        }
    }

    private struct MainActorClosure: @unchecked Sendable {
        let closure: @MainActor (String) -> Void
    }
    private struct MainActorToolClosure: @unchecked Sendable {
        let closure: @MainActor (String, String, String, Bool) -> Void
    }

    // --- Event bus ---

    func listEvents(workspaceID: String, afterID: Int64 = 0, limit: Int32 = 50) async -> [Atelier_V1_Event] {
        guard let stub else { return [] }
        do {
            let r = try await stub.listEvents(.with {
                $0.workspaceID = workspaceID
                $0.afterID = afterID
                $0.limit = limit
            })
            return r.items
        } catch {
            self.lastError = "events: \(error)"
            return []
        }
    }

    // --- New project ---

    func proposeProject(idea: String, provider: String = "anthropic", model: String = "claude-sonnet-4-6") async -> Atelier_V1_ProjectProposal? {
        guard let stub else { return nil }
        do {
            let req = Atelier_V1_ProposeProjectRequest.with {
                $0.idea = idea
                $0.provider = provider
                $0.model = model
            }
            return try await stub.proposeProject(req)
        } catch {
            self.lastError = "propose: \(error)"
            return nil
        }
    }

    func scaffoldProject(proposal: Atelier_V1_ProjectProposal, parentDir: String) async -> Atelier_V1_ScaffoldProjectResponse? {
        guard let stub else { return nil }
        do {
            let req = Atelier_V1_ScaffoldProjectRequest.with {
                $0.proposal = proposal
                $0.parentDir = parentDir
            }
            let resp = try await stub.scaffoldProject(req)
            await refreshWorkspaces()
            return resp
        } catch {
            self.lastError = "scaffold: \(error)"
            return nil
        }
    }

    func applyTeam(workspaceID: String, provider: String = "anthropic", model: String = "claude-sonnet-4-6") async -> Atelier_V1_ApplyTeamResponse? {
        guard let stub else { return nil }
        do {
            let req = Atelier_V1_ApplyTeamRequest.with {
                $0.workspaceID = workspaceID
                $0.provider = provider
                $0.model = model
            }
            return try await stub.applyTeam(req)
        } catch {
            self.lastError = "apply team: \(error)"
            return nil
        }
    }
}
