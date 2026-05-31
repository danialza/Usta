import SwiftUI
import AtelierProto

enum ChatItemKind { case user, assistant, tool, approval }

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
    var callID: String = ""
    var resolved: Bool = false  // approval acted on
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

    func resolveApproval(_ msgID: UUID, callID: String, allow: Bool, client: AtelierClientModel) {
        client.approveTool(callID: callID, allow: allow)
        if let i = messages.firstIndex(where: { $0.id == msgID }) {
            messages[i].resolved = true
            messages[i].toolOutput = allow ? "approved" : "denied"
        }
    }

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
            onApproval: { [weak self] callID, name, input in
                guard let self else { return }
                var row = ChatMessage(kind: .approval, role: self.role.name, emoji: "🔐", content: "")
                row.toolName = name; row.toolInput = input; row.callID = callID
                if let id = self.activeReplyID, let ri = self.messages.firstIndex(where: { $0.id == id }) {
                    self.messages.insert(row, at: ri)
                } else {
                    self.messages.append(row)
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
    var collapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    @EnvironmentObject var client: AtelierClientModel
    @StateObject private var model: ChatPaneModel

    enum Backend: String { case chat, cli }

    @State private var input: String = ""
    @State private var providers: [Atelier_V1_ProviderInfo] = []
    @State private var selectedProvider: String = ""
    @State private var selectedModel: String = ""
    @State private var backend: Backend = .chat
    @State private var cliCommand: String = ""
    @State private var cliSession: TerminalSession? = nil
    @State private var cliLaunching: Bool = false
    @State private var showRoleEditor: Bool = false

    init(workspaceID: String,
         role: Atelier_V1_Role,
         collapsed: Bool = false,
         onToggleCollapse: (() -> Void)? = nil) {
        self.workspaceID = workspaceID
        self.role = role
        self.collapsed = collapsed
        self.onToggleCollapse = onToggleCollapse
        _model = StateObject(wrappedValue: ChatPaneModel(role: role, workspaceID: workspaceID))
        _selectedProvider = State(initialValue: role.defaultProvider)
        _selectedModel = State(initialValue: role.defaultModel)
        // Default to CLI: explicit role.cliCommand wins, else derive from
        // provider (legacy role yamls without cli_command still get CLI mode).
        let derived = !role.cliCommand.isEmpty
            ? role.cliCommand
            : Self.defaultCommand(provider: role.defaultProvider, model: role.defaultModel)
        if !derived.isEmpty {
            _backend = State(initialValue: .cli)
            _cliCommand = State(initialValue: derived)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !collapsed {
                capabilities
                Divider().overlay(AtelierTheme.border)
                bodyContent
            }
        }
        .background(AtelierTheme.cell)
        .task {
            providers = await client.listProviders()
            await model.loadHistory(client: client)
            if cliCommand.isEmpty {
                cliCommand = !role.cliCommand.isEmpty
                    ? role.cliCommand
                    : Self.defaultCommand(provider: selectedProvider, model: selectedModel)
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        Group {
            if backend == .cli {
                cliView
            } else {
                transcript
                Divider().overlay(AtelierTheme.border)
                composer
            }
        }
    }

    static func defaultCommand(provider: String, model: String) -> String {
        switch provider {
        case "anthropic": return "claude"
        case "gemini":    return "gemini"
        case "ollama":    return "aider --model ollama_chat/\(model) --yes-always"
        default:          return ""
        }
    }

    @ViewBuilder
    private var cliView: some View {
        ZStack {
            Color.black
            if let s = cliSession {
                PtyTerminalView(session: s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(cliLaunching ? "starting \(cliCommand)…" : "preparing…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AtelierTheme.dim)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Auto-launch as soon as the CLI pane appears (no manual button).
            if cliSession == nil && !cliLaunching {
                let cmd = cliCommand.trimmingCharacters(in: .whitespaces)
                if !cmd.isEmpty {
                    cliLaunching = true
                    await launchCLI()
                    cliLaunching = false
                }
            }
        }
    }

    private func launchCLI() async {
        guard let t = await client.createTerminal(workspaceID: workspaceID, command: cliCommand, role: role.name) else { return }
        let session = TerminalSession(id: t.id, title: cliCommand)
        session.roleName = role.name
        if let stub = client.ptyStub() { session.start(stub: stub) }
        cliSession = session
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
            if !collapsed {
                Picker("", selection: $backend) {
                    Image(systemName: "bubble.left.and.text.bubble.right").tag(Backend.chat)
                    Image(systemName: "terminal").tag(Backend.cli)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .onChange(of: selectedProvider) { _, p in
                    if cliSession == nil { cliCommand = !role.cliCommand.isEmpty ? role.cliCommand : Self.defaultCommand(provider: p, model: selectedModel) }
                }
                .onChange(of: selectedModel) { _, m in
                    if cliSession == nil { cliCommand = !role.cliCommand.isEmpty ? role.cliCommand : Self.defaultCommand(provider: selectedProvider, model: m) }
                }
                providerPicker
                modelPicker
            }
            if backend == .cli {
                Button {
                    cliSession?.stop()
                    cliSession = nil
                    // Refresh derived command from current provider/model.
                    cliCommand = !role.cliCommand.isEmpty ? role.cliCommand
                        : Self.defaultCommand(provider: selectedProvider, model: selectedModel)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AtelierTheme.dim)
                .help("Relaunch CLI with current provider/model")
            }
            Button { showRoleEditor = true } label: {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(AtelierTheme.dim)
            .help("Edit role")
            if let toggle = onToggleCollapse {
                Button(action: toggle) {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AtelierTheme.dim)
            }
        }
        .padding(10)
        .sheet(isPresented: $showRoleEditor) {
            RoleEditor(existing: role, onSave: { updated in
                Task {
                    _ = await client.addRole(workspaceID: workspaceID, role: updated)
                }
            })
        }
    }

    @ViewBuilder
    private var capabilities: some View {
        let skills = role.claudeSkills
        let pubs = role.handoffPublishes
        let subs = role.handoffSubscribes
        if !skills.isEmpty || !pubs.isEmpty || !subs.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(skills, id: \.self) { s in
                    tag("skill:\(s)", color: .purple, full: "Claude skill: \(s) — \(Self.skillDescribe(s))")
                }
                ForEach(pubs, id: \.self) { p in
                    tag("↑\(p)", color: AtelierTheme.roleColor(for: role.name), full: "publishes \(p) — \(Self.topicDescribe(p))")
                }
                ForEach(subs, id: \.self) { s in
                    tag("↓\(s)", color: AtelierTheme.dim, full: "subscribes \(s) — \(Self.topicDescribe(s))")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func tag(_ text: String, color: Color, full: String) -> some View {
        let short = text.count > 22 ? (String(text.prefix(20)) + "…") : text
        return Text(short)
            .font(.system(size: 9, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
            .help(full)
    }

    /// 1-line plain description for a dotted topic name.
    static func topicDescribe(_ topic: String) -> String {
        switch topic {
        case "api.added":              return "a new HTTP/RPC endpoint shipped"
        case "api.changed":            return "an existing endpoint's contract changed"
        case "schema.changed":         return "the database schema was updated"
        case "schema.proposed":        return "a schema change is proposed and needs review"
        case "schema.ready":           return "the schema is approved and ready to apply"
        case "migration.applied":      return "a DB migration was applied"
        case "auth.implemented":       return "authentication is implemented"
        case "auth.flows.defined":     return "auth flows have been defined"
        case "auth.guidelines":        return "security guidelines for auth shipped"
        case "tests.failing":          return "tests are failing"
        case "tests.passed":           return "tests pass"
        case "tests.needed":           return "new tests are needed"
        case "security.finding":       return "a security issue was found"
        case "security.cleared":       return "the area was cleared by security"
        case "security.vulnerability.found": return "a vulnerability was found"
        case "security.review.complete":     return "security review is complete"
        case "deploy.ready":           return "the build is ready to deploy"
        case "deploy.rolled_back":     return "a deploy was rolled back"
        case "ui.component.added":     return "a new UI component shipped"
        case "ui.page.created":        return "a new page shipped"
        case "design.spec.ready":      return "design spec is ready"
        case "data.event.added":       return "a new data event/stream"
        case "data.model.defined":     return "data models defined"
        case "data.processed":         return "data was processed/transformed"
        case "payments.setup":         return "payments are configured"
        case "payment.integration.setup": return "payment integration set up"
        case "release.readiness.report":  return "release readiness report"
        case "test.report.generated":     return "test report generated"
        case "bug.found":                 return "a bug was found"
        case "code.pushed":               return "code pushed to the repo"
        case "code.committed":            return "code committed"
        case "ci.pipeline.configured":    return "CI pipeline configured"
        case "environment.ready":         return "environment is ready"
        case "app.deployed":              return "app deployed"
        case "data.migration.completed":  return "data migration completed"
        case "ui.form.validated":         return "form validation passed"
        case "ui.page.created":           return "UI page created"
        case "requirements.updated":      return "requirements were updated"
        case "requirements.defined":      return "requirements defined"
        case "feature.request":           return "a new feature request"
        case "data.proposal":             return "a data proposal"
        case "data.model.define":         return "data model definition"
        case "devops.infra.ready":        return "infra is ready"
        case "payments.integrated":       return "payments integrated"
        default:                          return "team event"
        }
    }

    static func skillDescribe(_ s: String) -> String {
        switch s {
        case "pdf":                return "read/extract/fill/create PDFs"
        case "xlsx":               return "read/edit/create spreadsheets"
        case "docx":               return "create/edit Word docs"
        case "pptx":               return "create/edit PowerPoint decks"
        case "skill-creator":      return "author new Claude skills"
        case "consolidate-memory": return "merge/prune long-term memory"
        case "setup-cowork":       return "guided Cowork setup"
        default:                   return "custom skill"
        }
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
        } else if msg.kind == .approval {
            approvalRow(msg)
        } else {
            chatBubble(msg)
        }
    }

    private func approvalRow(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill").font(.system(size: 11)).foregroundStyle(.yellow)
                Text("Approve \(msg.toolName)?").font(.system(size: 12, weight: .semibold))
            }
            Text(msg.toolInput).font(.system(size: 10, design: .monospaced))
                .foregroundStyle(AtelierTheme.dim).lineLimit(3)
            if msg.resolved {
                Text(msg.toolOutput == "approved" ? "✓ approved" : "✕ denied")
                    .font(.system(size: 11))
                    .foregroundStyle(msg.toolOutput == "approved" ? .green : .red)
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { model.resolveApproval(msg.id, callID: msg.callID, allow: true, client: client) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button("Deny") { model.resolveApproval(msg.id, callID: msg.callID, allow: false, client: client) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.yellow.opacity(0.4)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

