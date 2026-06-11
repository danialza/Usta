import Foundation
import SwiftUI
import AtelierProto

/// Per-role cache of ChatPaneModel objects. Survives ChatPane view
/// re-mounts on role-chip focus switches so the messages list, providers,
/// and "did we load history yet" sentinel stay alive — no repeated gRPC
/// listProviders + getHistory on every focus toggle.
@MainActor
final class ChatPaneModelCache: ObservableObject {
    private var models: [String: ChatPaneModel] = [:]

    /// Lookup or create the model for a role. Caller must pass a builder
    /// (since ChatPaneModel needs role + workspaceID at init).
    func model(for role: String, build: () -> ChatPaneModel) -> ChatPaneModel {
        if let existing = models[role] { return existing }
        let fresh = build()
        models[role] = fresh
        return fresh
    }

    func drop(role: String) { models.removeValue(forKey: role) }
    func clear() { models.removeAll() }

    // Process-wide cached provider list (rarely changes; refetch on demand)
    @Published var cachedProviders: [Atelier_V1_ProviderInfo] = []
    private var providersLoaded = false

    func providers(via client: UstaClientModel) async -> [Atelier_V1_ProviderInfo] {
        if providersLoaded { return cachedProviders }
        let list = await client.listProviders()
        cachedProviders = list
        providersLoaded = true
        return list
    }
}
