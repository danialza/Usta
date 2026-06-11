import Foundation
import SwiftUI

/// Per-workspace cache of live TerminalSession objects, keyed by role name.
///
/// Without this, every chip-tap or grid focus change tore down the
/// ChatPane → dropped its @State cliSession → next mount opened a brand
/// new StreamPty bidi RPC, replayed scrollback from DB, re-sent the role
/// brief. That was the lag.
///
/// The cache survives view destruction, so a pane re-attached to its
/// existing session in O(1) and SwiftTerm just rebinds.
@MainActor
final class TerminalSessionCache: ObservableObject {
    private var sessions: [String: TerminalSession] = [:]

    /// Lookup an existing session for a role.
    func session(for role: String) -> TerminalSession? {
        sessions[role]
    }

    /// Store a freshly-spawned session.
    func store(_ session: TerminalSession, for role: String) {
        sessions[role] = session
    }

    /// Drop a role's session (e.g. user invoked Refresh / Relaunch).
    /// Caller is responsible for calling `.stop()` first.
    func drop(role: String) {
        sessions.removeValue(forKey: role)
    }

    /// Tear everything down — used on workspace switch.
    func clear() {
        for s in sessions.values { s.stop() }
        sessions.removeAll()
    }
}
