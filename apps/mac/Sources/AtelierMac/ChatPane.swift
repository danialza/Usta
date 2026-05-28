import SwiftUI
import AtelierProto

struct ChatMessage: Identifiable {
    let id = UUID()
    var role: String      // "user" | "<role-name>"
    var emoji: String
    var content: String
    var pending: Bool = false
    var error: String? = nil
}

@MainActor
final class ChatPaneModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isStreaming: Bool = false

    let role: Atelier_V1_Role
    let workspaceID: String

    init(role: Atelier_V1_Role, workspaceID: String) {
        self.role = role
        self.workspaceID = workspaceID
    }

    func send(_ text: String, provider: String, model: String, client: AtelierClientModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(role: "user", emoji: "🧑", content: trimmed))
        let pendingIndex = messages.count
        messages.append(ChatMessage(role: role.name, emoji: role.emoji, content: "", pending: true))
        isStreaming = true

        client.roleChat(
            roleName: role.name,
            userMsg: trimmed,
            workspaceID: workspaceID,
            provider: provider,
            model: model,
            onToken: { [weak self] tok in
                guard let self else { return }
                guard pendingIndex - 1 < self.messages.count else { return }
                self.messages[pendingIndex - 1 + 1].content.append(tok)
            },
            onDone: { [weak self] _ in
                guard let self else { return }
                if pendingIndex - 1 + 1 < self.messages.count {
                    self.messages[pendingIndex - 1 + 1].pending = false
                }
                self.isStreaming = false
            },
            onError: { [weak self] err in
                guard let self else { return }
                if pendingIndex - 1 + 1 < self.messages.count {
                    self.messages[pendingIndex - 1 + 1].pending = false
                    self.messages[pendingIndex - 1 + 1].error = err
                }
                self.isStreaming = false
            }
        )
    }
}

/// Backwards-compatible alias — the chat surface is the assistant pane.
typealias ChatPane = AssistantPane

struct AssistantPane: View {
    let workspaceID: String
    let role: Atelier_V1_Role
    @EnvironmentObject var client: AtelierClientModel
    @StateObject private var model: ChatPaneModel

    @State private var input: String = ""
    @State private var providers: [Atelier_V1_ProviderInfo] = []
    @State private var selectedProvider: String = ""
    @State private var selectedModel: String = ""

    init(workspaceID: String, role: Atelier_V1_Role) {
        self.workspaceID = workspaceID
        self.role = role
        _model = StateObject(wrappedValue: ChatPaneModel(role: role, workspaceID: workspaceID))
        _selectedProvider = State(initialValue: role.defaultProvider)
        _selectedModel = State(initialValue: role.defaultModel)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            capabilities
            Divider().overlay(AtelierTheme.border)
            transcript
            Divider().overlay(AtelierTheme.border)
            composer
        }
        .background(AtelierTheme.cell)
        .task { providers = await client.listProviders() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            let emoji = role.emoji.isEmpty
                ? AtelierTheme.roleEmoji(for: role.name, fallback: "•") : role.emoji
            Text(emoji).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(AtelierTheme.roleColor(for: role.name)).frame(width: 7, height: 7)
                    Text(role.name).font(.headline)
                }
                Text(role.description_p).font(.caption).foregroundStyle(AtelierTheme.dim).lineLimit(1)
            }
            Spacer()
            providerPicker
            modelPicker
        }
        .padding(10)
    }

    @ViewBuilder
    private var capabilities: some View {
        let skills = role.claudeSkills
        let pubs = role.handoffPublishes
        let subs = role.handoffSubscribes
        if !skills.isEmpty || !pubs.isEmpty || !subs.isEmpty {
            HStack(spacing: 6) {
                ForEach(skills, id: \.self) { s in
                    tag("skill:\(s)", color: .purple)
                }
                ForEach(pubs, id: \.self) { p in
                    tag("↑\(p)", color: AtelierTheme.roleColor(for: role.name))
                }
                ForEach(subs, id: \.self) { s in
                    tag("↓\(s)", color: AtelierTheme.dim)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var providerPicker: some View {
        Menu {
            ForEach(providers, id: \.name) { p in
                Button {
                    selectedProvider = p.name
                    if !p.defaultModels.contains(selectedModel) {
                        selectedModel = p.defaultModels.first ?? role.defaultModel
                    }
                } label: {
                    HStack {
                        Image(systemName: p.available ? "checkmark.circle.fill" : "circle.slash")
                            .foregroundStyle(p.available ? .green : .secondary)
                        Text(p.name)
                    }
                }
            }
        } label: {
            Label(selectedProvider.isEmpty ? "provider" : selectedProvider, systemImage: "server.rack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var modelPicker: some View {
        let models: [String] = providers.first(where: { $0.name == selectedProvider })?.defaultModels ?? [role.defaultModel]
        return Menu {
            ForEach(models, id: \.self) { m in
                Button(m) { selectedModel = m }
            }
        } label: {
            Label(selectedModel.isEmpty ? "model" : selectedModel, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.messages) { msg in
                        bubble(msg).id(msg.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ msg: ChatMessage) -> some View {
        let isUser = msg.role == "user"
        HStack(alignment: .top, spacing: 8) {
            if !isUser { Text(msg.emoji).font(.title3) }
            VStack(alignment: .leading, spacing: 4) {
                Text(isUser ? "you" : msg.role).font(.caption2).foregroundStyle(.secondary)
                if let err = msg.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                } else {
                    Text(msg.content.isEmpty && msg.pending ? "…" : msg.content)
                        .textSelection(.enabled)
                        .padding(10)
                        .background(isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            if isUser { Spacer(minLength: 0) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask \(role.name)…", text: $input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "paperplane.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(model.isStreaming || input.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func send() {
        let text = input
        input = ""
        model.send(text, provider: selectedProvider, model: selectedModel, client: client)
    }
}

