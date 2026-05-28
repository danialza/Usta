import SwiftUI
import AtelierProto

enum ChatItemKind { case user, assistant, tool }

struct ChatMessage: Identifiable {
    let id = UUID()
    var kind: ChatItemKind = .assistant
    var role: String      // "user" | "<role-name>"
    var emoji: String
    var content: String
    var pending: Bool = false
    var error: String? = nil
    // tool fields
    var toolName: String = ""
    var toolInput: String = ""
    var toolOutput: String = ""
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

    private var activeReplyID: UUID? = nil
    private(set) var historyLoaded = false

    func loadHistory(client: AtelierClientModel) async {
        if historyLoaded { return }
        historyLoaded = true
        let items = await client.getHistory(workspaceID: workspaceID, agentRole: role.name)
        guard !items.isEmpty else { return }
        var restored: [ChatMessage] = []
        for m in items {
            if m.role == "user" {
                restored.append(ChatMessage(kind: .user, role: "user", emoji: "🧑", content: m.content))
            } else {
                restored.append(ChatMessage(kind: .assistant, role: role.name, emoji: role.emoji, content: m.content))
            }
        }
        // Prepend history before any in-session messages.
        messages = restored + messages
    }

    func send(_ text: String, provider: String, model: String, client: AtelierClientModel) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(kind: .user, role: "user", emoji: "🧑", content: trimmed))
        let reply = ChatMessage(kind: .assistant, role: role.name, emoji: role.emoji, content: "", pending: true)
        activeReplyID = reply.id
        messages.append(reply)
        isStreaming = true

        client.roleChat(
            roleName: role.name,
            userMsg: trimmed,
            workspaceID: workspaceID,
            provider: provider,
            model: model,
            onToken: { [weak self] tok in
                guard let self, let id = self.activeReplyID,
                      let i = self.messages.firstIndex(where: { $0.id == id }) else { return }
                self.messages[i].content.append(tok)
            },
            onTool: { [weak self] name, input, output, isResult in
                guard let self else { return }
                if isResult {
                    // Attach output to the most recent matching pending tool row.
                    if let i = self.messages.lastIndex(where: { $0.kind == .tool && $0.toolName == name && $0.toolOutput.isEmpty }) {
                        self.messages[i].toolOutput = output
                        self.messages[i].pending = false
                    }
                } else {
                    // New tool-call row, inserted before the active reply bubble.
                    var row = ChatMessage(kind: .tool, role: self.role.name, emoji: "🔧", content: "", pending: true)
                    row.toolName = name; row.toolInput = input
                    if let id = self.activeReplyID, let ri = self.messages.firstIndex(where: { $0.id == id }) {
                        self.messages.insert(row, at: ri)
                    } else {
                        self.messages.append(row)
                    }
                }
            },
            onDone: { [weak self] _ in
                guard let self, let id = self.activeReplyID,
                      let i = self.messages.firstIndex(where: { $0.id == id }) else { self?.isStreaming = false; return }
                self.messages[i].pending = false
                self.isStreaming = false
                self.activeReplyID = nil
            },
            onError: { [weak self] err in
                guard let self else { return }
                if let id = self.activeReplyID, let i = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages[i].pending = false
                    self.messages[i].error = err
                }
                self.isStreaming = false
                self.activeReplyID = nil
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
        .task {
            providers = await client.listProviders()
            await model.loadHistory(client: client)
        }
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
                    if model.isStreaming {
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.45).frame(width: 12, height: 12)
                            Text("working").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
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
        if msg.kind == .tool {
            toolRow(msg)
        } else {
            chatBubble(msg)
        }
    }

    private func toolRow(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 10)).foregroundStyle(.orange)
                Text(msg.toolName).font(.system(size: 11, weight: .semibold))
                Text(msg.toolInput).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(AtelierTheme.dim).lineLimit(1)
                if msg.pending { ProgressView().scaleEffect(0.4) }
            }
            if !msg.toolOutput.isEmpty {
                let hasDiff = msg.toolOutput.contains("\n- ") || msg.toolOutput.contains("\n+ ")
                    || msg.toolOutput.hasPrefix("- ") || msg.toolOutput.hasPrefix("+ ")
                Group {
                    if hasDiff {
                        diffView(msg.toolOutput)
                    } else {
                        Text(msg.toolOutput)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AtelierTheme.dim)
                            .lineLimit(10)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AtelierTheme.cell)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func diffView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).prefix(20).enumerated()), id: \.offset) { _, raw in
                let line = String(raw)
                let color: Color = line.hasPrefix("- ") ? .red
                    : line.hasPrefix("+ ") ? .green : AtelierTheme.dim
                let bg: Color = line.hasPrefix("- ") ? Color.red.opacity(0.10)
                    : line.hasPrefix("+ ") ? Color.green.opacity(0.10) : .clear
                Text(line.isEmpty ? " " : line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(bg)
            }
        }
    }

    @ViewBuilder
    private func chatBubble(_ msg: ChatMessage) -> some View {
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

