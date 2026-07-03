import SwiftUI
import AppKit
import UstaProto

struct ContentView: View {
    @EnvironmentObject var client: UstaClientModel
    @EnvironmentObject var settings: AppSettings
    @State private var selection: Usta_V1_Workspace?
    @State private var showNewProject = false
    @State private var showSettings = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    @StateObject private var updates = UpdateChecker()

    var body: some View {
        VStack(spacing: 0) {
            UpdateBanner(checker: updates)
            Group {
                if client.workspaces.isEmpty {
                    WelcomeView(
                        onOpen: { Task { await openFolder() } },
                        onNew: { showNewProject = true },
                        onSettings: { showSettings = true }
                    )
                } else {
                    NavigationSplitView(columnVisibility: $sidebarVisibility) {
                        sidebar
                    } detail: {
                        detail
                    }
                    .environment(\.sidebarCollapsed,
                                 sidebarVisibility == .detailOnly)
                }
            }
        }
        .task { await updates.checkOnLaunch() }
        .preferredColorScheme(.dark)
        .background(BrandBackground().ignoresSafeArea())
        .background(ChromelessWindow())
        .sheet(isPresented: $showNewProject) {
            NewProjectWizard(onOpened: { ws in selection = ws })
                .environmentObject(client)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(client)
                .environmentObject(settings)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider().overlay(UstaTheme.border)
            sidebarBody
        }
        .background(UstaTheme.sidebar.opacity(0.85).ignoresSafeArea())
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            UstaLogo(size: 22)
            Text("Usta").font(.headline)
            Spacer()
            Circle()
                .fill(client.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.daemonVersion.map { "v\($0)" } ?? "—")
                .font(.caption2).foregroundStyle(UstaTheme.dim)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(UstaTheme.dim)
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)        // clear macOS traffic lights
        .padding(.bottom, 14)
    }

    private var sidebarBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Workspaces", trailing: openButton) {
                    if client.workspaces.isEmpty {
                        sidebarPlaceholder("No projects open.")
                    }
                    ForEach(client.workspaces, id: \.id) { ws in
                        WorkspaceRow(
                            ws: ws,
                            selected: selection?.id == ws.id,
                            onTap: { selection = ws },
                            onRemove: {
                                let id = ws.id
                                Task {
                                    await client.closeWorkspace(id: id)
                                    if selection?.id == id { selection = nil }
                                }
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 14)
        }
    }

    private var openButton: some View {
        Menu {
            Button { showNewProject = true } label: { Label("New Project…", systemImage: "sparkles") }
            Button { Task { await openFolder() } } label: { Label("Open Folder…", systemImage: "folder") }
        } label: {
            Image(systemName: "plus").font(.caption.weight(.bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(UstaTheme.dim)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String, trailing: some View = EmptyView(),
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UstaTheme.dim2)
                    .tracking(1)
                Spacer()
                trailing
            }
            .padding(.horizontal, 6)
            content()
        }
    }

    private func sidebarPlaceholder(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(UstaTheme.dim)
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder
    private var detail: some View {
        if let ws = selection {
            WorkspaceDetailView(ws: ws)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.3.group.bubble")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(UstaTheme.dim2)
                Text("Pick a workspace from the sidebar.")
                    .foregroundStyle(UstaTheme.dim)
                if let err = client.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url {
            await client.openWorkspace(path: url.path)
        }
    }
}

struct WorkspaceRow: View {
    let ws: Usta_V1_Workspace
    let selected: Bool
    var onTap: () -> Void
    var onRemove: (() -> Void)? = nil
    @State private var hover: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.system(size: 13, weight: .medium))
                Text(ws.path).font(.system(size: 11))
                    .foregroundStyle(UstaTheme.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
            if hover, let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(UstaTheme.dim)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? UstaTheme.border : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { hover = $0 }
        .contextMenu {
            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: ws.path))
            } label: { Label("Open in Finder", systemImage: "folder") }
            Button {
                openInEditor(name: "Visual Studio Code", path: ws.path)
            } label: { Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right") }
            Button {
                openInEditor(name: "Cursor", path: ws.path)
            } label: { Label("Open in Cursor", systemImage: "cursorarrow.click") }
            Divider()
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove from list", systemImage: "minus.circle")
                }
            }
        }
    }

    /// Open `path` in `name` (e.g. "Visual Studio Code"). Uses `/usr/bin/open
    /// -a` with an argument array — no shell, so paths with quotes/spaces are
    /// safe (no injection). If the app isn't installed, open fails silently.
    private func openInEditor(name: String, path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", name, path]   // argv, not a shell string
        try? task.run()
    }
}

struct WelcomeView: View {
    var onOpen: () -> Void
    var onNew: () -> Void = {}
    var onSettings: () -> Void = {}

    var body: some View {
        ZStack {
            // Layer 1 — brand bg + luxury pattern, same as main scene
            BrandBackground()

            // Layer 2 — top-right settings cog
            VStack {
                HStack {
                    Spacer()
                    Button(action: onSettings) {
                        Image(systemName: "gearshape").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(UstaTheme.dim)
                    .padding(.trailing, 20)
                    .padding(.top, 30)            // clear traffic lights
                }
                Spacer()
            }

            // Layer 3 — true-centered hero
            VStack(spacing: 22) {
                UstaLogo(size: 96)
                Text("Welcome to Usta").font(.system(size: 32, weight: .semibold))
                Text("Your AI engineering team, on your desktop")
                    .font(.system(size: 14))
                    .foregroundStyle(UstaTheme.dim)
                HStack(spacing: 18) {
                    welcomeCard(
                        icon: "folder.badge.plus",
                        title: "Open Existing Project",
                        desc: "Point at a folder. Usta analyzes the codebase and suggests a team of specialists tailored to your stack.",
                        action: onOpen
                    )
                    welcomeCard(
                        icon: "sparkles",
                        title: "Start From Scratch",
                        desc: "Describe what you want to build. PM agent picks a stack, scaffolds the project, and spawns the assistant team.",
                        action: onNew
                    )
                }
                .frame(maxWidth: 720)
                .padding(.top, 8)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func welcomeCard(icon: String, title: String, desc: String,
                             disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(UstaTheme.dim)
                    .lineSpacing(2)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 180, alignment: .topLeading)
            .background(UstaTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(disabled ? UstaTheme.border : Color.accentColor.opacity(0.6),
                            lineWidth: disabled ? 1 : 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.55 : 1.0)
        .disabled(disabled)
    }
}

enum DetailMode { case assistants, graph, terminals }

struct WorkspaceDetailView: View {
    let ws: Usta_V1_Workspace
    @EnvironmentObject var client: UstaClientModel
    @StateObject private var grid = TerminalGridModel()
    @State private var roles: [Usta_V1_Role] = []
    @State private var selectedRole: Usta_V1_Role? = nil   // focus a single assistant
    @State private var mode: DetailMode = .assistants
    @State private var showApplyTeam = false
    @State private var showAddRole = false
    @State private var applyInFlight = false
    @State private var applyResult: String? = nil
    @State private var terminalsLoaded = false
    @State private var showActivity = true
    @State private var startingTeam = false
    @State private var newFeatureText: String = ""
    @State private var showNewFeature: Bool = false
    @State private var newFeatureRole: String = "product-manager"
    // Team templates: export / import
    @State private var importConfirmYaml: String? = nil
    @State private var templateStatus: String? = nil
    // Cost dashboard
    @State private var showCosts = false
    // Session replay
    @State private var showReplay = false
    // Workshop grill: post-scaffold refinement
    @State private var showGrillMore: Bool = false
    @State private var grillMoreLoading: Bool = false
    @State private var grillMoreQs: [Usta_V1_GrillQuestion] = []
    @State private var grillMoreAns: [String: String] = [:]
    @StateObject private var bus = WorkspaceBus()
    @StateObject private var rate = RateLimitModel()
    @StateObject private var termCache = TerminalSessionCache()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(UstaTheme.border)
                switch mode {
                case .assistants:
                    AssistantsGrid(workspaceID: ws.id, roles: roles, focus: selectedRole?.name,
                                   onClearFocus: { selectedRole = nil })
                        .environmentObject(bus)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .graph:
                    HandoffGraphView(roles: roles)
                        .environmentObject(bus)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .terminals:
                    if grid.sessions.isEmpty { empty } else { terminals }
                }
            }
            .frame(maxWidth: .infinity)
            if showActivity {
                Divider().overlay(UstaTheme.border)
                ActivityFeed(workspaceID: ws.id)
                    .environmentObject(bus)
                    .frame(width: 320)
            }
        }
        .environmentObject(bus)
        .environmentObject(termCache)
        // Intentionally NOT ignoring top safe area — SwiftUI's safe
        // area already accounts for the title bar (windowed) and menu
        // bar (full-screen) so content is never hidden under chrome.
        .overlay(alignment: .topTrailing) {
            ToastStack().environmentObject(bus)
        }
        // Run/Open buttons focus a single pane full-screen — no auto-send.
        .onReceive(NotificationCenter.default.publisher(for: .ustaFocusRole)) { note in
            guard let name = note.object as? String,
                  let r = roles.first(where: { $0.name == name }) else { return }
            selectedRole = r
            mode = .assistants   // graph/terminal taps land on the live pane
        }
        .task(id: ws.id) {
            roles = await client.listRoles(workspaceID: ws.id)
            bus.start(workspaceID: ws.id, client: client, roles: roles)
            rate.start(client: client) { msg in
                bus.toast(kind: .info, title: "Anthropic rate limit", body: msg)
            }
        }
        .onDisappear { bus.stop(); rate.stop() }
        .alert("Import team template?", isPresented: Binding(
            get: { importConfirmYaml != nil },
            set: { if !$0 { importConfirmYaml = nil } }
        )) {
            Button("Replace current team", role: .destructive) {
                if let y = importConfirmYaml { importTeam(yaml: y, replace: true) }
                importConfirmYaml = nil
            }
            Button("Merge with current team") {
                if let y = importConfirmYaml { importTeam(yaml: y, replace: false) }
                importConfirmYaml = nil
            }
            Button("Cancel", role: .cancel) { importConfirmYaml = nil }
        } message: {
            Text("Replace deletes this workspace's existing roles first. Merge keeps them and adds/overwrites by name.")
        }
        .alert("Team template", isPresented: Binding(
            get: { templateStatus != nil },
            set: { if !$0 { templateStatus = nil } }
        )) {
            Button("OK") { templateStatus = nil }
        } message: {
            Text(templateStatus ?? "")
        }
        .sheet(isPresented: $showCosts) {
            CostDashboard(workspaceID: ws.id)
                .environmentObject(client)
        }
        .sheet(isPresented: $showReplay) {
            ReplayView(workspaceName: (ws.path as NSString).lastPathComponent)
                .environmentObject(bus)
        }
        .sheet(isPresented: $showApplyTeam) { applyTeamSheet }
        .sheet(isPresented: $showAddRole) {
            RoleEditor(onSave: { newRole in
                Task {
                    if let added = await client.addRole(workspaceID: ws.id, role: newRole) {
                        roles.append(added)
                    }
                }
            })
        }
        .sheet(isPresented: $showGrillMore) { grillMoreSheet }
    }

    // MARK: Workshop grill

    private func openGrillMore() async {
        grillMoreLoading = true
        defer { grillMoreLoading = false }
        // Synthesize a ProjectProposal from current workspace roles so we
        // can reuse the existing GenerateGrillQuestions RPC.
        let synth = Usta_V1_ProjectProposal.with {
            $0.projectName = ws.name
            $0.projectSlug = ws.name.lowercased().replacingOccurrences(of: " ", with: "-")
            $0.summary = "In-flight project, refining mid-workshop."
            $0.team = roles.map { r in
                Usta_V1_ProposedRole.with {
                    $0.name = r.name
                    $0.emoji = r.emoji
                    $0.why = r.description_p
                    $0.recommendedProvider = r.defaultProvider
                    $0.recommendedModel = r.defaultModel
                    $0.tools = r.allowedTools
                    $0.claudeSkills = r.claudeSkills
                    $0.publishes = r.handoffPublishes
                    $0.subscribes = r.handoffSubscribes
                    $0.cliCommand = r.cliCommand
                    $0.kickoff = r.kickoff
                }
            }
        }
        let qs = await client.generateGrillQuestions(idea: ws.name, proposal: synth)
        grillMoreQs = qs
        grillMoreAns = [:]
        if !qs.isEmpty { showGrillMore = true }
        else { bus.toast(kind: .info, title: "Grill",
                         body: client.lastError ?? "no questions returned") }
    }

    private var grillMoreSheet: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(.tint)
                Text("Grill more — refine the project").font(.headline)
                Spacer()
                Button("Close") { showGrillMore = false }.buttonStyle(.borderless)
            }.padding(14)
            Divider().overlay(UstaTheme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Answer what's relevant. Skip the rest. Your answers will be sent to PM as a refinement request — affected roles get fresh tasks.")
                        .font(.callout).foregroundStyle(UstaTheme.dim)
                    ForEach(Array(grillMoreQs.enumerated()), id: \.offset) { idx, q in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(idx + 1).").font(.body.bold()).foregroundStyle(UstaTheme.dim)
                                Text(q.question).font(.body.bold())
                            }
                            if !q.rationale.isEmpty {
                                Text(q.rationale).font(.caption).foregroundStyle(UstaTheme.dim)
                            }
                            if !q.options.isEmpty {
                                FlowLayout(spacing: 6) {
                                    ForEach(q.options, id: \.self) { opt in
                                        let selected = grillMoreAns[q.id] == opt
                                        Button { grillMoreAns[q.id] = selected ? "" : opt } label: {
                                            Text(opt).font(.caption)
                                                .padding(.horizontal, 10).padding(.vertical, 4)
                                                .background(selected ? Color.accentColor.opacity(0.25) : UstaTheme.cell)
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : UstaTheme.border))
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .foregroundStyle(.primary)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            if q.allowFreeText {
                                TextField("Or type your own…",
                                          text: Binding(
                                            get: { grillMoreAns[q.id] ?? "" },
                                            set: { grillMoreAns[q.id] = $0 }))
                                    .textFieldStyle(.plain).font(.system(size: 12))
                                    .padding(8).background(UstaTheme.cell)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(UstaTheme.border))
                            }
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(UstaTheme.cell.opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UstaTheme.border))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }.padding(18)
            }
            Divider().overlay(UstaTheme.border)
            HStack {
                Spacer()
                Button {
                    Task { await applyGrillMore() }
                } label: { Label("Apply Answers", systemImage: "sparkles") }
                .buttonStyle(.borderedProminent)
                .disabled(grillMoreAns.values.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            }.padding(14)
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(UstaTheme.panel)
    }

    private func applyGrillMore() async {
        let qa: [(String, String)] = grillMoreQs.compactMap { q in
            let a = (grillMoreAns[q.id] ?? "").trimmingCharacters(in: .whitespaces)
            return a.isEmpty ? nil : (q.question, a)
        }
        guard !qa.isEmpty else { return }
        var text = "Project refinement based on additional grill answers:\n\n"
        for (q, a) in qa { text += "- \(q) → \(a)\n" }
        showGrillMore = false
        bus.toast(kind: .info, title: "Refining…",
                  body: "PM is updating affected roles' tasks.")
        if let plan = await client.orchestrateFeature(workspaceID: ws.id, featureText: text) {
            roles = await client.listRoles(workspaceID: ws.id)
            bus.updateRoles(roles)
            bus.resetAutoRegenGuards()
            bus.setOrchestrationOrder(plan.roles.map { $0.name })
            bus.refreshNow(workspaceID: ws.id)
            for r in plan.roles {
                NotificationCenter.default.post(name: .ustaResetKickoff, object: r.name)
            }
            let names = plan.roles.map { "@\($0.name)" }.joined(separator: ", ")
            bus.toast(kind: .ready,
                      title: "Refinement applied — \(plan.roles.count) role(s)",
                      body: names)
        } else {
            bus.toast(kind: .info, title: "Refinement failed",
                      body: client.lastError ?? "unknown")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Menu {
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: ws.path)) } label: {
                        Label("Open in Finder", systemImage: "folder")
                    }
                    Button {
                        let p = Process(); p.launchPath = "/usr/bin/open"
                        p.arguments = ["-a", "Visual Studio Code", ws.path]
                        try? p.run()
                    } label: {
                        Label("Open in VS Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Button {
                        let p = Process(); p.launchPath = "/usr/bin/open"
                        p.arguments = ["-a", "Cursor", ws.path]
                        try? p.run()
                    } label: {
                        Label("Open in Cursor", systemImage: "cursorarrow.click")
                    }
                    Button {
                        let p = Process(); p.launchPath = "/usr/bin/open"
                        p.arguments = ["-a", "Terminal", ws.path]
                        try? p.run()
                    } label: {
                        Label("Open in Terminal", systemImage: "terminal")
                    }
                } label: {
                    Image(systemName: "folder.fill.badge.gear")
                        .font(.system(size: 26))
                        .foregroundStyle(.tint)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(ws.path).font(.system(size: 11))
                        .foregroundStyle(UstaTheme.dim)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .layoutPriority(0.5)
                Spacer(minLength: 8)
                // Responsive trailing toolbar: full labels → icon-only →
                // ultra-compact (primary + overflow Menu).
                ViewThatFits(in: .horizontal) {
                    toolbarRow(compact: false, includeOverflow: false)
                    toolbarRow(compact: true,  includeOverflow: false)
                    toolbarRow(compact: true,  includeOverflow: true)
                }
            }
            if !roles.isEmpty && mode == .assistants {
                roleChipsStrip
                nextActionBar
                newFeatureBar
            }
        }
        // Responsive: when sidebar is collapsed, modifier adds large
        // leading + top padding to clear traffic-lights + toggle button.
        // When sidebar is open, modifier uses minimal padding so the
        // title hugs the workspace pane's left edge.
        .modifier(SidebarAwareLeadingPadding())
        .padding(.trailing, 14)
        .padding(.bottom, 10)
    }

    /// Collapsed "💡 New feature" entry: text input → publishes a
    /// `feature.requested` event from the user, routed to the picked role.
    /// Triggers auto-regen for that role's pane → they get a fresh kickoff
    /// referencing the new ask.
    @ViewBuilder
    private var newFeatureBar: some View {
        if !showNewFeature {
            Button { showNewFeature = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb").font(.system(size: 11))
                    Text("Add new feature or change…")
                        .font(.system(size: 11)).foregroundStyle(UstaTheme.dim)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(UstaTheme.cell.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
                TextField("Describe the new feature or change…", text: $newFeatureText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { submitNewFeature() }
                Picker("", selection: $newFeatureRole) {
                    ForEach(roles, id: \.name) { r in
                        Text("→ @\(r.name)").tag(r.name)
                    }
                }
                .pickerStyle(.menu).fixedSize()
                Button("Send") { submitNewFeature() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(newFeatureText.trimmingCharacters(in: .whitespaces).isEmpty)
                Button {
                    showNewFeature = false; newFeatureText = ""
                } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.borderless).foregroundStyle(UstaTheme.dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.yellow.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.yellow.opacity(0.4)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func submitNewFeature() {
        let text = newFeatureText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        Task {
            bus.toast(kind: .info, title: "Planning feature…",
                      body: "PM is deciding which roles act and writing tasks.")
            if let plan = await client.orchestrateFeature(workspaceID: ws.id, featureText: text) {
                // Reload roles so updated kickoff yamls land in UI
                roles = await client.listRoles(workspaceID: ws.id)
                bus.updateRoles(roles)
                bus.resetAutoRegenGuards()   // allow re-fire for re-opened roles
                bus.setOrchestrationOrder(plan.roles.map { $0.name })
                bus.refreshNow(workspaceID: ws.id)
                // Wake each affected pane with new banner
                for r in plan.roles {
                    NotificationCenter.default.post(name: .ustaResetKickoff, object: r.name)
                }
                let names = plan.roles.map { "@\($0.name)" }.joined(separator: ", ")
                bus.toast(kind: .ready,
                          title: "Plan ready — \(plan.roles.count) role(s)",
                          body: "\(names). Open their panes; tasks pre-loaded.")
            } else {
                bus.toast(kind: .info, title: "Plan failed",
                          body: client.lastError ?? "unknown error")
            }
            await MainActor.run {
                newFeatureText = ""
                showNewFeature = false
            }
        }
    }

    /// Single-line "what to do RIGHT NOW" computed from bus state.
    private var nextActionBar: some View {
        let working = roles.filter { bus.state(of: $0.name) == .working }.map { $0.name }
        let ready   = bus.readyNow
        let done    = roles.filter { bus.state(of: $0.name) == .done }.map { $0.name }
        let total   = roles.count

        // Pick the role the user should focus. Pin lives in the bus and is
        // refreshed only when state meaningfully changes — bar stays steady.
        let focusName: String? = {
            if let w = working.first { return w }
            if let r = ready.first { return r }
            return bus.pinnedBottleneckName
        }()

        let (icon, color, title, body): (String, Color, String, String) = {
            if let w = working.first {
                return ("clock.arrow.circlepath", .orange, "Working",
                        "@\(w) is running. Click bar to open its pane.")
            }
            if let r = ready.first {
                return ("arrow.right.circle.fill", .accentColor, "Do next",
                        "@\(r) is ready. Click ▶ Run or open its pane and Send.")
            }
            if done.count == total {
                return ("checkmark.seal.fill", .green, "All done",
                        "Every role published its outputs. Clean checkpoint.")
            }
            if let bn = bus.bottleneck() {
                if bn.cycle {
                    return ("arrow.triangle.2.circlepath", .yellow, "Cycle — break it",
                            "All pending roles wait on each other. Open @\(bn.name) (blocks \(bn.dependents) other(s)) and type the next prompt manually.")
                }
                return ("hand.point.right.fill", .yellow, "Unblock @\(bn.name)",
                        "@\(bn.name) blocks \(bn.dependents) other role(s). Click bar to open its pane, then Send or type into its terminal.")
            }
            return ("ellipsis.circle", .gray, "Idle", "Nothing ready. Click Refresh.")
        }()

        let content = HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
                Text(body).font(.system(size: 12)).foregroundStyle(.primary).lineLimit(2)
            }
            Spacer()
            if let r = ready.first {
                Button {
                    if let role = roles.first(where: { $0.name == r }) { selectedRole = role }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 10))
                        Text("Open @\(r)").font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor).foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open @\(r) full-screen. Review its prompt, then Send.")
            } else if let f = focusName {
                let unpub = bus.unpublishedFor(f)
                if !unpub.isEmpty {
                    Button {
                        Task {
                            for t in unpub {
                                _ = await client.publishEvent(
                                    workspaceID: ws.id, fromRole: f, topic: t,
                                    summary: "manually marked done by user — \(t)"
                                )
                            }
                            bus.refreshNow(workspaceID: ws.id)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                            Text("Mark @\(f) done").font(.system(size: 11, weight: .medium))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.green).foregroundStyle(.white)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Force-publish remaining topics for @\(f): \(unpub.joined(separator: ", "))")
                } else {
                    Text("Open @\(f) →").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(color)
                }
            }
            Text("\(done.count)/\(total) done")
                .font(.system(size: 10)).foregroundStyle(UstaTheme.dim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(color.opacity(0.10))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.40)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(RoundedRectangle(cornerRadius: 8))

        return content.onTapGesture {
            if let f = focusName, let r = roles.first(where: { $0.name == f }) {
                selectedRole = r   // filter grid to that pane
            }
        }
    }

    private var roleChipsStrip: some View {
        // Canonical bus ordering: working > ready > bottleneck > pending > done.
        let ordered = bus.orderedRoles(roles)
        return FlowLayout(spacing: 6) {
            RoleChipAll(selected: selectedRole == nil) { selectedRole = nil }
            ForEach(ordered, id: \.name) { r in
                chip(for: r)
            }
        }
        // No animation on the chip strip reorder — it lagged chip taps.
    }

    @ViewBuilder
    private func chip(for r: Usta_V1_Role) -> some View {
        let isSel = selectedRole?.name == r.name
        let tip: String = r.description_p.isEmpty ? r.name : "\(r.name) — \(r.description_p)"
        RoleChip(role: r, selected: isSel) {
            if isSel { selectedRole = nil } else { selectedRole = r }
        }
        .help(tip)
        .contextMenu {
            Button(role: .destructive) {
                let name = r.name
                Task {
                    await client.deleteRole(workspaceID: ws.id, name: name)
                    roles.removeAll { $0.name == name }
                    if selectedRole?.name == name { selectedRole = nil }
                }
            } label: { Label("Delete role", systemImage: "trash") }
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Image(systemName: "person.3.sequence").tag(DetailMode.assistants)
            Image(systemName: "point.3.connected.trianglepath.dotted").tag(DetailMode.graph)
            Image(systemName: "terminal").tag(DetailMode.terminals)
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .onChange(of: mode) { _, newMode in
            if newMode == .terminals && !terminalsLoaded {
                terminalsLoaded = true
                Task { await grid.load(workspaceID: ws.id, client: client) }
            }
        }
    }

    /// One adaptive layout — full labels, icon-only, or icon + overflow Menu.
    /// Bulk-switch every role's terminal CLI at once (Claude → Codex etc.).
    /// Broadcasts to each pane, which relaunches with the new command. Roles
    /// pinned to a custom cli_command in their yaml are left untouched.
    @ViewBuilder
    private func cliSwitchMenu(compact: Bool) -> some View {
        Menu {
            Text("Switch ALL terminals to:").font(.caption)
            Button("Claude (claude)")     { setAllCLI("anthropic") }
            Button("Codex (codex)")       { setAllCLI("openai") }
            Button("Gemini (gemini)")     { setAllCLI("gemini") }
            Button("Aider · Ollama")      { setAllCLI("ollama") }
        } label: {
            if compact {
                Image(systemName: "terminal").frame(width: 30, height: 24)
            } else {
                Label("CLI", systemImage: "terminal")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch every role's terminal to one CLI (claude / codex / gemini / aider)")
    }

    private func setAllCLI(_ provider: String) {
        NotificationCenter.default.post(name: .ustaSetAllCLI, object: provider)
        bus.toast(kind: .info, title: "Switching CLIs",
                  body: "All roles → \(provider). Relaunching terminals…")
    }

    // MARK: - Worktrees

    /// Per-workspace opt-in for role worktrees, persisted in UserDefaults.
    private var worktreeBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "usta.worktrees.\(ws.id)") },
            set: { UserDefaults.standard.set($0, forKey: "usta.worktrees.\(ws.id)") }
        )
    }

    /// Per-workspace opt-in for cross-vendor auto-review.
    private var crossReviewBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "usta.crossreview.\(ws.id)") },
            set: { UserDefaults.standard.set($0, forKey: "usta.crossreview.\(ws.id)") }
        )
    }

    private func mergeRole(_ name: String) {
        Task {
            guard let r = await client.mergeRoleBranch(workspaceID: ws.id, role: name) else {
                templateStatus = client.lastError ?? "merge failed"
                return
            }
            let tail = r.output.split(separator: "\n").suffix(4).joined(separator: "\n")
            templateStatus = r.ok
                ? "Merged @\(name)'s branch.\n\(tail)"
                : "Merge failed (aborted, tree left clean):\n\(tail)"
        }
    }

    // MARK: - Team templates

    /// Export this workspace's team as a shareable `.ustateam.yaml`.
    private func exportTeamToFile() {
        Task {
            let wsName = (ws.path as NSString).lastPathComponent
            guard let yaml = await client.exportTeam(workspaceID: ws.id, name: wsName) else {
                templateStatus = client.lastError ?? "export failed"
                return
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(wsName).ustateam.yaml"
            panel.title = "Export Team Template"
            if panel.runModal() == .OK, let url = panel.url {
                try? yaml.write(to: url, atomically: true, encoding: .utf8)
                templateStatus = "Team exported → \(url.lastPathComponent)"
            }
        }
    }

    /// Pick a template file, then confirm replace-vs-merge before applying.
    private func pickTeamFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Team Template"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url,
           let yaml = try? String(contentsOf: url, encoding: .utf8) {
            importConfirmYaml = yaml
        }
    }

    private func importTeam(yaml: String, replace: Bool) {
        Task {
            guard let imported = await client.importTeam(workspaceID: ws.id, yaml: yaml, replace: replace) else {
                templateStatus = client.lastError ?? "import failed"
                return
            }
            roles = await client.listRoles(workspaceID: ws.id)
            bus.updateRoles(roles)
            templateStatus = "Imported \(imported.count) roles"
        }
    }

    private func toolbarRow(compact: Bool, includeOverflow: Bool) -> some View {
        HStack(spacing: 8) {
            modePicker
            RateLimitChip(model: rate)
            tbBtn("Run App", "play.rectangle.fill", compact: compact) {
                PreviewRunner.run(at: ws.path)
            }
            tbBtn("Refresh", "arrow.clockwise", compact: compact) {
                Task {
                    roles = await client.listRoles(workspaceID: ws.id)
                    bus.updateRoles(roles)
                    bus.refreshNow(workspaceID: ws.id)
                }
            }
            if !roles.isEmpty && mode == .assistants {
                tbBtn(startingTeam ? "Starting…" : "Start Team",
                      startingTeam ? "hourglass" : "play.fill",
                      compact: compact) {
                    if !startingTeam { Task { await startTeamSequentially() } }
                }
                cliSwitchMenu(compact: compact)
            }
            if includeOverflow {
                Menu {
                    Button(showActivity ? "Hide Activity" : "Activity") { showActivity.toggle() }
                    Button("Add Role") { showAddRole = true }
                    Button("Apply Team") { showApplyTeam = true }
                    Button("Costs…") { showCosts = true }
                    Button("Replay…") { showReplay = true }
                    Divider()
                    Button("Export Team…") { exportTeamToFile() }
                    Button("Import Team…") { pickTeamFile() }
                    Divider()
                    Toggle("Cross-review (other vendor)", isOn: crossReviewBinding)
                        .help("When a role publishes *.ready, a different-vendor role (Claude ↔ Codex) gets a review prompt in its pane. You still hit Send.")
                    Toggle("Worktree per role", isOn: worktreeBinding)
                        .help("New role terminals run on their own git branch (usta/<role>) in an isolated worktree — no file conflicts between agents.")
                    if worktreeBinding.wrappedValue {
                        Menu("Merge role branch") {
                            ForEach(roles, id: \.name) { r in
                                Button("@\(r.name) → current branch") { mergeRole(r.name) }
                            }
                        }
                    }
                    if !roles.isEmpty && mode == .assistants {
                        Button(grillMoreLoading ? "Grilling…" : "Grill More") {
                            if !grillMoreLoading { Task { await openGrillMore() } }
                        }
                    }
                    if mode == .terminals {
                        Button("New Terminal") {
                            Task { await grid.newTerminal(workspaceID: ws.id, client: client) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption.weight(.medium))
                        .frame(width: 30, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More")
            } else {
                tbBtn(showActivity ? "Hide Activity" : "Activity",
                      "dot.radiowaves.left.and.right", compact: compact) {
                    showActivity.toggle()
                }
                tbBtn("Add Role", "plus", compact: compact) { showAddRole = true }
                tbBtn("Apply Team", "person.3.sequence", compact: compact) { showApplyTeam = true }
                tbBtn("Costs", "dollarsign.circle", compact: compact) { showCosts = true }
                tbBtn("Replay", "memories", compact: compact) { showReplay = true }
                Menu {
                    Button("Export Team…") { exportTeamToFile() }
                    Button("Import Team…") { pickTeamFile() }
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                        .font(.caption.weight(.medium))
                        .frame(width: 30, height: 24)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Share team as a template / import one")
                if !roles.isEmpty && mode == .assistants {
                    tbBtn(grillMoreLoading ? "Grilling…" : "Grill More",
                          grillMoreLoading ? "hourglass" : "questionmark.bubble",
                          compact: compact) {
                        if !grillMoreLoading { Task { await openGrillMore() } }
                    }
                }
                if mode == .terminals {
                    tbBtn("New Terminal", "plus.rectangle.on.rectangle", compact: compact) {
                        Task { await grid.newTerminal(workspaceID: ws.id, client: client) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tbBtn(_ title: String, _ icon: String, compact: Bool, action: @escaping () -> Void) -> some View {
        if compact { toolbarIcon(title, systemImage: icon, action: action) }
        else       { toolbarButton(title, systemImage: icon, action: action) }
    }

    private func toolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(UstaTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: UstaTheme.radiusSmall).stroke(UstaTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: UstaTheme.radiusSmall))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(title)
    }

    /// Icon-only variant — used when the window is too narrow for labels.
    private func toolbarIcon(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.medium))
                .frame(width: 30, height: 24)
                .background(UstaTheme.panel)
                .overlay(RoundedRectangle(cornerRadius: UstaTheme.radiusSmall).stroke(UstaTheme.border))
                .clipShape(RoundedRectangle(cornerRadius: UstaTheme.radiusSmall))
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 38))
                .foregroundStyle(UstaTheme.dim2)
            Text("No terminals open in this workspace.")
                .foregroundStyle(UstaTheme.dim)
            Button {
                Task { await grid.newTerminal(workspaceID: ws.id, client: client) }
            } label: {
                Label("Open the first one", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminals: some View {
        let cols = max(1, min(grid.sessions.count, 2))
        let layout = Array(repeating: GridItem(.flexible(), spacing: 8), count: cols)
        return ScrollView {
            LazyVGrid(columns: layout, spacing: 8) {
                ForEach(grid.sessions) { session in
                    TerminalCell(session: session) {
                        Task { await grid.closeTerminal(id: session.id, client: client) }
                    }
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var applyTeamSheet: some View {
        VStack(spacing: 16) {
            Text("Apply Team").font(.title2.bold())
            Text("Usta will analyze \(ws.name) and write a custom team to .usta/roles/.")
                .multilineTextAlignment(.center)
                .foregroundStyle(UstaTheme.dim)
            if let r = applyResult {
                Text(r).font(.caption).foregroundStyle(.green)
            }
            HStack {
                Button("Cancel") { showApplyTeam = false; applyResult = nil }
                Spacer()
                Button {
                    Task { await runApplyTeam() }
                } label: {
                    if applyInFlight { ProgressView() } else { Text("Run") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(applyInFlight)
            }
        }
        .padding(24)
        .frame(width: 420)
        .background(UstaTheme.panel)
    }

    private func runApplyTeam() async {
        applyInFlight = true
        defer { applyInFlight = false }
        if let resp = await client.applyTeam(workspaceID: ws.id) {
            applyResult = "wrote \(resp.writtenPaths.count) role file(s)"
            roles = await client.listRoles(workspaceID: ws.id)
        } else if let e = client.lastError {
            applyResult = e
        }
    }

    /// Send kickoff to each role one at a time, in dependency order:
    /// roles with no `subscribes` go first (they generate events others wait on);
    /// downstream roles last. Within a tier, preserve PM-given order.
    private func startTeamSequentially() async {
        startingTeam = true
        defer { startingTeam = false }
        let ordered = topoSorted(roles)
        for r in ordered {
            guard !r.kickoff.isEmpty else { continue }
            NotificationCenter.default.post(
                name: .ustaKickoffRole,
                object: r.name
            )
            // Give the role time to: (a) receive its prompt, (b) call MCP,
            // (c) possibly publish an event. 8s is a sane minimum; downstream
            // roles will still wait on the event bus via wait_for_event.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
        }
    }

    /// Kahn's algorithm over handoff topics. A role depends on roles that
    /// publish any topic it subscribes to.
    private func topoSorted(_ all: [Usta_V1_Role]) -> [Usta_V1_Role] {
        // topic -> publishers
        var producers: [String: Set<String>] = [:]
        for r in all {
            for t in r.handoffPublishes {
                producers[t, default: []].insert(r.name)
            }
        }
        // name -> set of upstream role names
        var upstream: [String: Set<String>] = [:]
        for r in all {
            var deps: Set<String> = []
            for t in r.handoffSubscribes {
                if let pubs = producers[t] {
                    for p in pubs where p != r.name { deps.insert(p) }
                }
            }
            upstream[r.name] = deps
        }
        // Iteratively peel off roles whose upstream is satisfied.
        var remaining = all
        var out: [Usta_V1_Role] = []
        var done: Set<String> = []
        while !remaining.isEmpty {
            let ready = remaining.filter { (upstream[$0.name] ?? []).isSubset(of: done) }
            if ready.isEmpty {
                // Cycle or missing producer — drain remaining in given order.
                out.append(contentsOf: remaining)
                break
            }
            out.append(contentsOf: ready)
            for r in ready { done.insert(r.name) }
            let readyNames = Set(ready.map { $0.name })
            remaining.removeAll { readyNames.contains($0.name) }
        }
        return out
    }
}

struct RoleChipAll: View {
    let selected: Bool
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Text("All").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.3) : UstaTheme.panel)
                .overlay(Capsule().stroke(selected ? Color.accentColor : UstaTheme.border,
                                          lineWidth: selected ? 1.2 : 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RoleChip: View {
    let role: Usta_V1_Role
    let selected: Bool
    var onTap: () -> Void
    @EnvironmentObject var bus: WorkspaceBus
    var body: some View {
        let working = bus.state(of: role.name) == .working
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(UstaTheme.roleColor(for: role.name))
                    .frame(width: 8, height: 8)
                    .opacity(working ? 0.7 : 1.0)         // static dim, no pulse
                let emoji = role.emoji.isEmpty
                    ? UstaTheme.roleEmoji(for: role.name, fallback: "•")
                    : role.emoji
                Text("\(emoji) \(role.name)")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? UstaTheme.roleColor(for: role.name).opacity(0.30)
                                : UstaTheme.panel)
            .overlay(Capsule().stroke(
                working ? Color.red
                    : (selected ? UstaTheme.roleColor(for: role.name) : UstaTheme.border),
                lineWidth: working ? 1.6 : (selected ? 1.2 : 1)
            ))
            // The repeatForever pulse rings were rendering every frame
            // forever — they were the real CPU + perceived-lag source.
            // Replaced with a static red outline when working.
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct TerminalCell: View {
    @ObservedObject var session: TerminalSession
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                roleBadge
                Text(session.title)
                    .font(.caption).foregroundStyle(UstaTheme.dim).lineLimit(1)
                Spacer()
                Circle()
                    .fill(session.alive ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(UstaTheme.dim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(UstaTheme.panel)
            Divider().overlay(UstaTheme.border)
            PtyTerminalView(session: session)
                .frame(minHeight: 220)
                .clipped()
        }
        .background(UstaTheme.cell)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UstaTheme.border))
    }

    private var roleBadge: some View {
        let name = session.roleName ?? "terminal"
        let color = UstaTheme.roleColor(for: name)
        let emoji = UstaTheme.roleEmoji(for: name, fallback: session.roleEmoji ?? "")
        return HStack(spacing: 4) {
            Text(emoji)
            Text(name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color)
        .clipShape(Capsule())
    }
}
