import SwiftUI
import UstaProto

extension Notification.Name {
    /// Posted with `object: role.name` to ask a pane to send its kickoff.
    static let ustaKickoffRole = Notification.Name("UstaKickoffRole")
    /// Posted with `object: subscriberRoleName` when a new event lands
    /// whose topic that role subscribes to. Pane reacts by regenerating.
    static let ustaEventForRole = Notification.Name("UstaEventForRole")
    /// Posted with `object: roleName` by the bus when a role should have
    /// its kickoff auto-regenerated (becomes bottleneck or newly ready).
    /// Pane dedups: only runs if regeneratedKickoff is nil.
    static let ustaAutoRegenerate = Notification.Name("UstaAutoRegenerate")
    /// Posted with `object: roleName` after OrchestrateFeature wrote a new
    /// kickoff into the role's yaml. Pane should re-show banner.
    static let ustaResetKickoff = Notification.Name("UstaResetKickoff")
    /// Posted with `object: roleName` to focus a single pane full-screen.
    /// Does NOT send anything — the user reviews + sends the prompt manually.
    static let ustaFocusRole = Notification.Name("UstaFocusRole")
    /// Posted with `object: providerId` ("anthropic"/"openai"/"gemini"/"ollama")
    /// to switch EVERY role's CLI at once (claude → codex, etc.). Each pane
    /// relaunches its terminal with the new command.
    static let ustaSetAllCLI = Notification.Name("UstaSetAllCLI")
}

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

    let role: Usta_V1_Role
    let workspaceID: String

    init(role: Usta_V1_Role, workspaceID: String) {
        self.role = role
        self.workspaceID = workspaceID
    }

    private var activeReplyID: UUID? = nil
    private(set) var historyLoaded = false

    func resolveApproval(_ msgID: UUID, callID: String, allow: Bool, client: UstaClientModel) {
        client.approveTool(callID: callID, allow: allow)
        if let i = messages.firstIndex(where: { $0.id == msgID }) {
            messages[i].resolved = true
            messages[i].toolOutput = allow ? "approved" : "denied"
        }
    }

    /// Static per-(workspace,role) cache so a chip toggle (which destroys
    /// and re-mounts the ChatPane @StateObject) doesn't re-fetch history
    /// over gRPC. Keyed by "\(workspaceID)|\(roleName)".
    private static var historyCache: [String: [ChatMessage]] = [:]
    private var cacheKey: String { "\(workspaceID)|\(role.name)" }

    func loadHistory(client: UstaClientModel) async {
        if historyLoaded { return }
        historyLoaded = true
        // Fast-path: already fetched once for this (workspace, role) →
        // restore from in-memory cache, skip the RPC.
        if let cached = Self.historyCache[cacheKey] {
            messages = cached
            return
        }
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
        // Cache so future re-mounts skip the gRPC roundtrip.
        Self.historyCache[cacheKey] = messages
    }

    func send(_ text: String, provider: String, model: String, client: UstaClientModel) {
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
    let role: Usta_V1_Role
    var collapsed: Bool = false
    var onToggleCollapse: (() -> Void)? = nil
    var isMaximized: Bool = false
    var onToggleMaximize: (() -> Void)? = nil
    var step: Int? = nil
    var stateColor: Color? = nil
    @EnvironmentObject var client: UstaClientModel
    @EnvironmentObject var bus: WorkspaceBus
    @EnvironmentObject var termCache: TerminalSessionCache
    @StateObject private var model: ChatPaneModel

    enum Backend: String { case chat, cli }

    @State private var input: String = ""
    @State private var providers: [Usta_V1_ProviderInfo] = []
    @State private var selectedProvider: String = ""
    @State private var selectedModel: String = ""
    @State private var backend: Backend = .chat
    @State private var cliCommand: String = ""
    @State private var cliSession: TerminalSession? = nil
    @State private var cliLaunching: Bool = false
    @State private var cliError: String? = nil
    @State private var showRoleEditor: Bool = false
    @State private var kickoffSent: Bool = false
    @State private var regenInFlight: Bool = false
    @State private var regeneratedKickoff: String? = nil
    /// The exact prompt text most recently sent to this pane. Survives Send so
    /// the user can re-show / re-send / copy it (e.g. after clearing the input).
    @State private var lastSentPrompt: String = ""
    @State private var showLastPrompt: Bool = false
    /// Guards against the provider-picker onChange re-entering switchCLI when
    /// switchCLI itself sets selectedProvider.
    @State private var switchingCLI: Bool = false
    /// Slash-command skills user has invoked in this pane's pty since launch.
    /// Set when we type the command in, cleared on relaunch.
    @State private var activatedSkills: Set<String> = []

    init(workspaceID: String,
         role: Usta_V1_Role,
         collapsed: Bool = false,
         onToggleCollapse: (() -> Void)? = nil,
         isMaximized: Bool = false,
         onToggleMaximize: (() -> Void)? = nil,
         step: Int? = nil,
         stateColor: Color? = nil) {
        self.workspaceID = workspaceID
        self.role = role
        self.collapsed = collapsed
        self.onToggleCollapse = onToggleCollapse
        self.isMaximized = isMaximized
        self.onToggleMaximize = onToggleMaximize
        self.step = step
        self.stateColor = stateColor
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
                kickoffBanner
                Divider().overlay(UstaTheme.border)
                bodyContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
        .background(UstaTheme.cell)
        .onReceive(NotificationCenter.default.publisher(for: .ustaKickoffRole)) { note in
            guard let name = note.object as? String, name == role.name else { return }
            if kickoffSent || role.kickoff.isEmpty { return }
            Task { await sendKickoff() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ustaEventForRole)) { note in
            guard let name = note.object as? String, name == role.name else { return }
            if regenInFlight { return }
            Task {
                regenInFlight = true
                if let k = await client.regenerateKickoff(workspaceID: workspaceID, roleName: role.name) {
                    regeneratedKickoff = k
                    kickoffSent = false   // surface new banner
                }
                regenInFlight = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ustaResetKickoff)) { note in
            guard let name = note.object as? String, name == role.name else { return }
            // Updated yaml has fresh kickoff text — re-show banner using that
            // (clear any stale regen + un-dismiss).
            regeneratedKickoff = nil
            kickoffSent = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .ustaSetAllCLI)) { note in
            guard let provider = note.object as? String else { return }
            Task { await switchCLI(to: provider) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ustaAutoRegenerate)) { note in
            guard let name = note.object as? String, name == role.name else { return }
            // Dedup: only auto-fire when we don't already have a regenerated
            // prompt waiting, no in-flight call, and the user hasn't sent yet.
            if regeneratedKickoff != nil || regenInFlight || kickoffSent { return }
            Task {
                regenInFlight = true
                if let k = await client.regenerateKickoff(workspaceID: workspaceID, roleName: role.name) {
                    regeneratedKickoff = k
                    kickoffSent = false
                }
                regenInFlight = false
            }
        }
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
                Divider().overlay(UstaTheme.border)
                composer
            }
        }
        .clipped()
    }

    static func defaultCommand(provider: String, model: String) -> String {
        switch provider {
        case "anthropic":
            // Pass --model so the picked Usta model (haiku/sonnet/opus)
            // actually reaches the claude CLI session. Without it, claude
            // uses its own account default (usually sonnet).
            return model.isEmpty ? "claude" : "claude --model \(model)"
        case "gemini":
            return model.isEmpty ? "gemini" : "gemini --model \(model)"
        case "openai":
            // OpenAI's Codex CLI. -m picks the model.
            return model.isEmpty ? "codex" : "codex -m \(model)"
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
                    .clipped()
            } else if let err = cliError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.title2)
                    Text("CLI failed to launch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(UstaTheme.dim)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 24)
                    HStack(spacing: 10) {
                        Button("Retry") {
                            cliError = nil
                            Task {
                                cliLaunching = true
                                await launchCLI()
                                cliLaunching = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Use chat instead") {
                            cliError = nil
                            backend = .chat
                        }
                        .buttonStyle(.bordered)
                    }
                    Text("Hint: `\(cliCommand)` — ensure it's installed and in PATH.")
                        .font(.caption2).foregroundStyle(UstaTheme.dim)
                }
                .padding()
            } else {
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(cliLaunching ? "starting \(cliCommand)…" : "preparing…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(UstaTheme.dim)
                    Button("Switch to chat") { backend = .chat }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .padding(.top, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // FAST PATH: this role already has a live session from a prior
            // pane mount → just rebind. No new RPC, no scrollback replay.
            if cliSession == nil, let cached = termCache.session(for: role.name) {
                cliSession = cached
                cliError = nil
                return
            }
            // Auto-launch as soon as the CLI pane appears (no manual button).
            if cliSession == nil && !cliLaunching && cliError == nil {
                let cmd = cliCommand.trimmingCharacters(in: .whitespaces)
                if cmd.isEmpty {
                    cliError = "no CLI command configured for this role"
                    return
                }
                cliLaunching = true
                await launchCLI()
                cliLaunching = false
            }
        }
    }

    /// Switch this pane's CLI to a new provider (claude → codex etc.). Kills
    /// the live terminal, recomputes the command, and relaunches. Ignores
    /// roles pinned to a custom cli_command in their yaml (respect explicit).
    private func switchCLI(to provider: String) async {
        // A role with an explicit custom command opts out of bulk switching.
        if !role.cliCommand.isEmpty { return }
        switchingCLI = true
        defer { switchingCLI = false }
        backend = .cli
        selectedProvider = provider
        let newCmd = Self.defaultCommand(provider: provider, model: "")
        if newCmd.isEmpty { return }
        cliCommand = newCmd
        // Tear down the current terminal so launchCLI doesn't reattach to it.
        if let s = cliSession {
            await client.closeTerminal(id: s.id)
            s.stop()
            cliSession = nil
            termCache.drop(role: role.name)
        }
        // Also close any other alive terminal for this role on the daemon.
        for t in await client.listTerminals(workspaceID: workspaceID)
            where t.role == role.name && t.alive {
            await client.closeTerminal(id: t.id)
        }
        cliError = nil
        cliLaunching = true
        await launchCLI()
        cliLaunching = false
    }

    private func launchCLI() async {
        // 1) Try reattach: find an alive terminal for this role on the
        // workspace. Survives pane re-mount (sidebar nav, role chip toggle).
        let existing = await client.listTerminals(workspaceID: workspaceID)
            .first { $0.role == role.name && $0.alive }
        let termID: String
        if let t = existing {
            termID = t.id
        } else {
            guard let t = await client.createTerminal(workspaceID: workspaceID, command: cliCommand, role: role.name) else {
                cliError = client.lastError ?? "createTerminal returned nil (daemon unreachable?)"
                return
            }
            termID = t.id
        }
        let session = TerminalSession(id: termID, title: cliCommand)
        session.roleName = role.name
        if let stub = client.ptyStub() {
            session.start(stub: stub)
        } else {
            cliError = "pty stub unavailable"
            return
        }
        cliSession = session
        termCache.store(session, for: role.name)      // survive view re-mount
        cliError = nil
        // Auto-activate universal skills on every fresh CLI session: type
        // `/caveman:caveman` then `/memsearch:memory-recall` after pty has
        // booted. Only fire on NEW terminals (existing reattach already has
        // them active from earlier).
        if existing == nil {
            Task { await sendSkillPrelude(session: session) }
        }
    }

    /// Inject `/caveman:caveman` + `/memsearch:memory-recall` (or other
    /// slash skills) into the freshly launched claude pty so every role
    /// boots into terse + memory-aware mode.
    private func sendSkillPrelude(session: TerminalSession) async {
        // Wait for claude to finish welcome banner + reach prompt
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        let preludes: [String] = [
            "/caveman:caveman",
            "/memsearch:memory-recall",
        ]
        for cmd in preludes {
            if let data = (cmd + "\n").data(using: .utf8) {
                await session.sendInput(data)
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: identity (emoji + name + description) — full pane width
            HStack(spacing: 8) {
                if let n = step {
                    Text("\(n)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(stateColor ?? UstaTheme.roleColor(for: role.name)))
                        .help("Step \(n) · \(stateLabel())")
                }
                let emoji = role.emoji.isEmpty
                    ? UstaTheme.roleEmoji(for: role.name, fallback: "•") : role.emoji
                Text(emoji).font(.title3)
                Circle().fill(UstaTheme.roleColor(for: role.name)).frame(width: 7, height: 7)
                Text(role.name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
                if model.isStreaming {
                    HStack(spacing: 3) {
                        ProgressView().scaleEffect(0.45).frame(width: 10, height: 10)
                        Text("working").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
                Spacer()
                if let maxToggle = onToggleMaximize {
                    Button(action: maxToggle) {
                        Image(systemName: isMaximized
                              ? "arrow.down.right.and.arrow.up.left"
                              : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UstaTheme.dim)
                    .help(isMaximized ? "Restore (show all)" : "Maximize (focus this pane)")
                }
                if let toggle = onToggleCollapse {
                    Button(action: toggle) {
                        Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UstaTheme.dim)
                    .help(collapsed ? "Expand body" : "Collapse to header")
                }
            }
            if !role.description_p.isEmpty {
                Text(role.description_p).font(.system(size: 10))
                    .foregroundStyle(UstaTheme.dim).lineLimit(1)
            }
            skillIndicatorRow
            // Row 2: controls — picker, provider, model, relaunch, gear
            if !collapsed {
                HStack(spacing: 6) {
                    Picker("", selection: $backend) {
                        Image(systemName: "bubble.left.and.text.bubble.right").tag(Backend.chat)
                        Image(systemName: "terminal").tag(Backend.cli)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .onChange(of: selectedProvider) { _, p in
                        if switchingCLI { return }
                        // Live CLI session + user picked a new provider → relaunch
                        // that terminal on the new CLI (claude → codex, etc.).
                        if backend == .cli && cliSession != nil && role.cliCommand.isEmpty {
                            Task { await switchCLI(to: p) }
                        } else if cliSession == nil {
                            cliCommand = !role.cliCommand.isEmpty ? role.cliCommand : Self.defaultCommand(provider: p, model: selectedModel)
                        }
                    }
                    .onChange(of: selectedModel) { _, m in
                        if cliSession == nil { cliCommand = !role.cliCommand.isEmpty ? role.cliCommand : Self.defaultCommand(provider: selectedProvider, model: m) }
                    }
                    providerPicker
                    modelPicker
                    Spacer(minLength: 0)
                    headerActions
                }
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
    private var headerActions: some View {
        let unpub = bus.unpublishedFor(role.name)
        HStack(spacing: 6) {
            if !unpub.isEmpty {
                Button {
                    Task { await markRoleDone(topics: unpub) }
                } label: {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Mark @\(role.name) done — force-publish \(unpub.count) remaining: \(unpub.joined(separator: ", "))")
            }
            if backend == .cli {
                Button {
                    cliSession?.stop()
                    termCache.drop(role: role.name)   // forget cache on relaunch
                    cliSession = nil
                    activatedSkills.removeAll()
                    cliCommand = !role.cliCommand.isEmpty ? role.cliCommand
                        : Self.defaultCommand(provider: selectedProvider, model: selectedModel)
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(UstaTheme.dim)
                .help("Relaunch CLI")
            }
            Button { showRoleEditor = true } label: {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(UstaTheme.dim)
            .help("Edit role")
        }
    }

    /// Publish each missing handoff topic on this role's behalf.
    /// Used when claude finished work but forgot to call publish_event.
    private func markRoleDone(topics: [String]) async {
        for t in topics {
            let summary = "manually marked done by user — \(t)"
            _ = await client.publishEvent(
                workspaceID: workspaceID,
                fromRole: role.name,
                topic: t,
                summary: summary
            )
        }
        // Force-poll so UI flips immediately.
        bus.refreshNow(workspaceID: workspaceID)
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
                    tag("↑\(p)", color: UstaTheme.roleColor(for: role.name), full: "publishes \(p) — \(Self.topicDescribe(p))")
                }
                ForEach(subs, id: \.self) { s in
                    tag("↓\(s)", color: UstaTheme.dim, full: "subscribes \(s) — \(Self.topicDescribe(s))")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    /// Small clickable chips showing which slash-command skills are active
    /// in this pane's pty. Gray = not invoked. Green = sent. Click to send.
    @ViewBuilder
    private var skillIndicatorRow: some View {
        if backend == .cli {
            let entries: [(slug: String, label: String)] = [
                ("caveman:caveman",        "🪨 caveman"),
                ("memsearch:memory-recall","🧠 memory"),
                ("grill-me",               "❓ grill"),
                ("tdd",                    "🧪 tdd"),
                ("diagnose",               "🔬 diagnose"),
            ]
            HStack(spacing: 4) {
                ForEach(entries, id: \.slug) { e in
                    skillChip(slug: e.slug, label: e.label)
                }
            }
        }
    }

    private func skillChip(slug: String, label: String) -> some View {
        let active = activatedSkills.contains(slug)
        return Button {
            Task { await invokeSkill(slug: slug) }
        } label: {
            HStack(spacing: 3) {
                Circle().fill(active ? Color.green : Color.gray.opacity(0.5))
                    .frame(width: 5, height: 5)
                Text(label).font(.system(size: 9, weight: active ? .semibold : .regular))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background((active ? Color.green : Color.gray).opacity(0.10))
            .overlay(Capsule().stroke((active ? Color.green : Color.gray).opacity(0.35)))
            .clipShape(Capsule())
            .foregroundStyle(active ? Color.green : UstaTheme.dim)
        }
        .buttonStyle(.plain)
        .help(active
              ? "\(slug) active in this pane"
              : "Click to invoke /\(slug) — activate skill")
    }

    /// Type "/<slug>\n" into the pty + mark active. If CLI not yet up, queue
    /// the activation for the next attach (kickoffSent path handles it).
    private func invokeSkill(slug: String) async {
        guard let s = cliSession else { return }
        let cmd = "/\(slug)\n"
        if let data = cmd.data(using: .utf8) {
            await s.sendInput(data)
            await MainActor.run { activatedSkills.insert(slug) }
        }
    }

    private var effectiveKickoff: String {
        regeneratedKickoff ?? role.kickoff
    }

    @ViewBuilder
    private var kickoffBanner: some View {
        let s = bus.state(of: role.name)
        // Done state wins: role published all outputs → stale "Next task"
        // suggestions are misleading. Clear regen too.
        if s == .done {
            doneBanner
                .onAppear {
                    if regeneratedKickoff != nil { regeneratedKickoff = nil; kickoffSent = true }
                }
        } else if regeneratedKickoff != nil && !kickoffSent {
            kickoffBannerCore
        } else if s == .pending {
            blockedBanner
        } else if !effectiveKickoff.isEmpty && !kickoffSent {
            kickoffBannerCore
        } else if !lastSentPrompt.isEmpty {
            // After Send the active banner is gone — keep a compact handle on
            // the last prompt so the user can re-read, re-send, or copy it.
            lastPromptBar
        }
    }

    @ViewBuilder
    private var lastPromptBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.uturn.backward").font(.system(size: 10))
                    .foregroundStyle(UstaTheme.dim)
                Text("Last prompt sent").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { withAnimation { showLastPrompt.toggle() } } label: {
                    Text(showLastPrompt ? "Hide" : "Show").font(.system(size: 10, weight: .medium))
                }.buttonStyle(.borderless)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lastSentPrompt, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly).font(.system(size: 10))
                }.buttonStyle(.borderless).help("Copy the last prompt")
                Button { Task { await resendLastPrompt() } } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "paperplane").font(.system(size: 9))
                        Text("Re-send").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor).foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Paste the last prompt back into the terminal (you press Enter to run)")
            }
            if showLastPrompt {
                Text(lastSentPrompt)
                    .font(.system(size: 11)).foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(UstaTheme.dim.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(UstaTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var kickoffBannerCore: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(regeneratedKickoff != nil ? "Next task (regenerated)" : "Kickoff from conductor")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                    if regeneratedKickoff != nil {
                        Text("NEW").font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange).foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }
                Text(effectiveKickoff)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Button("Send") {
                    Task { await sendKickoff() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button {
                    Task {
                        regenInFlight = true
                        if let k = await client.regenerateKickoff(workspaceID: workspaceID, roleName: role.name) {
                            regeneratedKickoff = k
                        }
                        regenInFlight = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        if regenInFlight { ProgressView().scaleEffect(0.5).frame(width: 9, height: 9) }
                        else { Image(systemName: "arrow.clockwise").font(.system(size: 9)) }
                        Text("Next task").font(.system(size: 9))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(regenInFlight)
                .help("Ask PM to regenerate this kickoff based on event log")
            }
            Button {
                kickoffSent = true
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(UstaTheme.dim)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var doneBanner: some View {
        let pubs = role.handoffPublishes
        let nextReady = bus.readyNow.filter { $0 != role.name }
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("Done").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
                if !pubs.isEmpty {
                    Text("Published: " + pubs.map { "↑\($0)" }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                if !nextReady.isEmpty {
                    Text("Next ready: " + nextReady.map { "@\($0)" }.joined(separator: ", "))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.tint)
                } else {
                    Text("Wait for upstream events, or type follow-up in terminal below.")
                        .font(.system(size: 10)).foregroundStyle(UstaTheme.dim)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.green.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.green.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    @ViewBuilder
    private var blockedBanner: some View {
        let missing = bus.missingFor(role.name)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: regenInFlight ? "sparkles" : "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(regenInFlight ? Color.accentColor : .gray)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(regenInFlight ? "Generating next prompt…" : "Waiting on upstream")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(regenInFlight ? Color.accentColor : .gray)
                ForEach(missing.prefix(4), id: \.topic) { m in
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down").font(.system(size: 8))
                            .foregroundStyle(.gray)
                        Text("\(m.topic)").font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text("from @\(m.from)").font(.system(size: 10)).foregroundStyle(UstaTheme.dim)
                    }
                }
                if missing.count > 4 {
                    Text("…+\(missing.count - 4) more").font(.system(size: 9)).foregroundStyle(UstaTheme.dim)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                Button {
                    Task {
                        regenInFlight = true
                        if let k = await client.regenerateKickoff(workspaceID: workspaceID, roleName: role.name) {
                            regeneratedKickoff = k
                            kickoffSent = false
                        }
                        regenInFlight = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if regenInFlight { ProgressView().scaleEffect(0.5).frame(width: 9, height: 9) }
                        else { Image(systemName: "sparkles").font(.system(size: 10)) }
                        Text("Generate prompt").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.85))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(regenInFlight)
                .help("Ask PM to write the next task even though upstream isn't ready (best-effort).")
                Text("or type freely in terminal ↓").font(.system(size: 9))
                    .foregroundStyle(UstaTheme.dim)
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.gray.opacity(0.30)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10).padding(.bottom, 6)
    }

    private func stateLabel() -> String {
        guard let c = stateColor else { return "pending — waiting on upstream" }
        if c == .green  { return "done — published its outputs" }
        if c == .blue   { return "ready — all upstream events arrived" }
        if c == .orange { return "working" }
        return "pending — waiting on upstream"
    }

    private func sendKickoff() async {
        let text = effectiveKickoff
        if text.isEmpty { return }
        kickoffSent = true
        lastSentPrompt = text          // keep for re-show / re-send / copy
        bus.markWorking(role.name)
        if backend == .cli {
            // Wait briefly so a freshly-launched CLI has its prompt up.
            if cliSession == nil { try? await Task.sleep(nanoseconds: 1_200_000_000) }
            guard let s = cliSession else { return }
            // Type text + Enter.
            if let data = (text + "\n").data(using: .utf8) {
                await s.sendInput(data)
            }
        } else {
            input = text
        }
    }

    /// Re-paste the last sent prompt into the CLI (e.g. user cleared the
    /// input). Does NOT auto-submit — they press Enter when ready.
    private func resendLastPrompt() async {
        guard backend == .cli, !lastSentPrompt.isEmpty else {
            input = lastSentPrompt
            return
        }
        if cliSession == nil { try? await Task.sleep(nanoseconds: 600_000_000) }
        guard let s = cliSession else { return }
        if let data = lastSentPrompt.data(using: .utf8) {
            await s.sendInput(data)
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
                .foregroundStyle(UstaTheme.dim).lineLimit(3)
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
                    .foregroundStyle(UstaTheme.dim).lineLimit(1)
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
                            .foregroundStyle(UstaTheme.dim)
                            .lineLimit(10)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UstaTheme.cell)
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
                    : line.hasPrefix("+ ") ? .green : UstaTheme.dim
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

