import Foundation
import SwiftUI
import AtelierProto

@MainActor
final class TerminalGridModel: ObservableObject {
    @Published var sessions: [TerminalSession] = []
    private var loadedFor: String? = nil

    func load(workspaceID: String, client: AtelierClientModel) async {
        if loadedFor == workspaceID && !sessions.isEmpty { return }
        loadedFor = workspaceID
        sessions.removeAll()

        let server = await client.listTerminals(workspaceID: workspaceID)
        let alive = server.filter { $0.alive }
        for t in alive {
            attach(terminal: t, client: client)
        }
        if sessions.isEmpty {
            // Auto-create one if the workspace has none alive.
            await newTerminal(workspaceID: workspaceID, client: client)
        }
    }

    func newTerminal(workspaceID: String, client: AtelierClientModel) async {
        guard let t = await client.createTerminal(workspaceID: workspaceID) else { return }
        attach(terminal: t, client: client)
    }

    func closeTerminal(id: String, client: AtelierClientModel) async {
        await client.closeTerminal(id: id)
        if let i = sessions.firstIndex(where: { $0.id == id }) {
            sessions[i].stop()
            sessions.remove(at: i)
        }
    }

    private func attach(terminal: Atelier_V1_Terminal, client: AtelierClientModel) {
        let session = TerminalSession(
            id: terminal.id,
            title: "\(terminal.shell) — \(URL(fileURLWithPath: terminal.cwd).lastPathComponent)"
        )
        if let stub = client.ptyStub() {
            session.start(stub: stub)
        }
        sessions.append(session)
    }
}
