import SwiftUI
import AppKit
import AtelierProto

struct ContentView: View {
    @EnvironmentObject var client: AtelierClientModel
    @EnvironmentObject var settings: AppSettings
    @State private var selection: Atelier_V1_Workspace?
    @State private var showNewProject = false
    @State private var showSettings = false

    var body: some View {
        Group {
            if client.workspaces.isEmpty {
                WelcomeView(
                    onOpen: { Task { await openFolder() } },
                    onNew: { showNewProject = true },
                    onSettings: { showSettings = true }
                )
            } else {
                NavigationSplitView { sidebar } detail: { detail }
            }
        }
        .preferredColorScheme(.dark)
        .background(AtelierTheme.bg)
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
            Divider().overlay(AtelierTheme.border)
            sidebarBody
        }
        .background(AtelierTheme.sidebar)
        .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.3.group.bubble")
                .foregroundStyle(.tint)
            Text("Atelier").font(.headline)
            Spacer()
            Circle()
                .fill(client.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.daemonVersion.map { "v\($0)" } ?? "—")
                .font(.caption2).foregroundStyle(AtelierTheme.dim)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AtelierTheme.dim)
        }
        .padding(14)
    }

    private var sidebarBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section(title: "Workspaces", trailing: openButton) {
                    if client.workspaces.isEmpty {
                        sidebarPlaceholder("No projects open.")
                    }
                    ForEach(client.workspaces, id: \.id) { ws in
                        WorkspaceRow(ws: ws, selected: selection?.id == ws.id) {
                            selection = ws
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                let id = ws.id
                                Task {
                                    await client.closeWorkspace(id: id)
                                    if selection?.id == id { selection = nil }
                                }
                            } label: { Label("Remove from list", systemImage: "minus.circle") }
                        }
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
        .foregroundStyle(AtelierTheme.dim)
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
                    .foregroundStyle(AtelierTheme.dim2)
                    .tracking(1)
                Spacer()
                trailing
            }
            .padding(.horizontal, 6)
            content()
        }
    }

    private func sidebarPlaceholder(_ s: String) -> some View {
        Text(s).font(.caption).foregroundStyle(AtelierTheme.dim)
            .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder
    private var detail: some View {
        if let ws = selection {
            WorkspaceDetailView(ws: ws)
                .background(AtelierTheme.bg)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.3.group.bubble")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(AtelierTheme.dim2)
                Text("Pick a workspace from the sidebar.")
                    .foregroundStyle(AtelierTheme.dim)
                if let err = client.lastError {
                    Text(err).font(.caption).foregroundStyle(.red).padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AtelierTheme.bg)
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
    let ws: Atelier_V1_Workspace
    let selected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name).font(.system(size: 13, weight: .medium))
                    Text(ws.path).font(.system(size: 11))
                        .foregroundStyle(AtelierTheme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AtelierTheme.border : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct WelcomeView: View {
    var onOpen: () -> Void
    var onNew: () -> Void = {}
    var onSettings: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.10, blue: 0.18), AtelierTheme.bg],
                startPoint: .top, endPoint: .bottom
            )
            Button(action: onSettings) {
                Image(systemName: "gearshape").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AtelierTheme.dim)
            .padding(20)
            VStack(spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.39, green: 0.40, blue: 0.95),
                                     Color(red: 0.93, green: 0.28, blue: 0.60)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 76, height: 76)
                    Image(systemName: "rectangle.3.group.bubble")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.white)
                }
                Text("Welcome to Atelier").font(.system(size: 30, weight: .semibold))
                Text("Your AI engineering team, on your desktop")
                    .foregroundStyle(AtelierTheme.dim)
                HStack(spacing: 18) {
                    welcomeCard(
                        icon: "folder.badge.plus",
                        title: "Open Existing Project",
                        desc: "Point at a folder. Atelier analyzes the codebase and suggests a team of specialists tailored to your stack.",
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
                .padding(.top, 24)
            }
            .padding(.horizontal, 40)
        }
    }

    private func welcomeCard(icon: String, title: String, desc: String,
                             disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.system(size: 28))
                    .foregroundStyle(.tint)
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(AtelierTheme.dim)
                    .lineSpacing(2)
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 180, alignment: .topLeading)
            .background(AtelierTheme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(disabled ? AtelierTheme.border : Color.accentColor.opacity(0.6),
                            lineWidth: disabled ? 1 : 1.2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.55 : 1.0)
        .disabled(disabled)
    }
}

enum DetailMode { case assistants, terminals }

struct WorkspaceDetailView: View {
    let ws: Atelier_V1_Workspace
    @EnvironmentObject var client: AtelierClientModel
    @StateObject private var grid = TerminalGridModel()
    @State private var roles: [Atelier_V1_Role] = []
    @State private var selectedRole: Atelier_V1_Role? = nil   // focus a single assistant
    @State private var mode: DetailMode = .assistants
    @State private var showApplyTeam = false
    @State private var showAddRole = false
    @State private var applyInFlight = false
    @State private var applyResult: String? = nil
    @State private var terminalsLoaded = false
    @State private var showActivity = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider().overlay(AtelierTheme.border)
                switch mode {
                case .assistants:
                    AssistantsGrid(workspaceID: ws.id, roles: roles, focus: selectedRole?.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AtelierTheme.bg)
                case .terminals:
                    if grid.sessions.isEmpty { empty } else { terminals }
                }
            }
            .frame(maxWidth: .infinity)
            if showActivity {
                Divider().overlay(AtelierTheme.border)
                ActivityFeed(workspaceID: ws.id)
                    .frame(width: 300)
            }
        }
        .background(AtelierTheme.bg)
        .task(id: ws.id) {
            roles = await client.listRoles(workspaceID: ws.id)
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
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill.badge.gear")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ws.name).font(.system(size: 16, weight: .semibold))
                    Text(ws.path).font(.system(size: 11))
                        .foregroundStyle(AtelierTheme.dim)
                        .textSelection(.enabled).lineLimit(1)
                }
                Spacer()
                modePicker
                toolbarButton(showActivity ? "Hide Activity" : "Activity",
                              systemImage: "dot.radiowaves.left.and.right") {
                    showActivity.toggle()
                }
                toolbarButton("Add Role", systemImage: "plus") {
                    showAddRole = true
                }
                toolbarButton("Apply Team", systemImage: "person.3.sequence") {
                    showApplyTeam = true
                }
                if mode == .terminals {
                    toolbarButton("New Terminal", systemImage: "plus.rectangle.on.rectangle") {
                        Task { await grid.newTerminal(workspaceID: ws.id, client: client) }
                    }
                }
            }
            if !roles.isEmpty && mode == .assistants {
                roleChipsStrip
            }
        }
        .padding(14)
    }

    private var roleChipsStrip: some View {
        FlowLayout(spacing: 6) {
            RoleChipAll(selected: selectedRole == nil) { selectedRole = nil }
            ForEach(roles, id: \.name) { r in
                chip(for: r)
            }
        }
    }

    @ViewBuilder
    private func chip(for r: Atelier_V1_Role) -> some View {
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

    private func toolbarButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AtelierTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(AtelierTheme.border))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "terminal").font(.system(size: 38))
                .foregroundStyle(AtelierTheme.dim2)
            Text("No terminals open in this workspace.")
                .foregroundStyle(AtelierTheme.dim)
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
            Text("Atelier will analyze \(ws.name) and write a custom team to .atelier/roles/.")
                .multilineTextAlignment(.center)
                .foregroundStyle(AtelierTheme.dim)
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
        .background(AtelierTheme.panel)
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
}

struct RoleChipAll: View {
    let selected: Bool
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            Text("All").font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.3) : AtelierTheme.panel)
                .overlay(Capsule().stroke(selected ? Color.accentColor : AtelierTheme.border,
                                          lineWidth: selected ? 1.2 : 1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RoleChip: View {
    let role: Atelier_V1_Role
    let selected: Bool
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AtelierTheme.roleColor(for: role.name))
                    .frame(width: 8, height: 8)
                let emoji = role.emoji.isEmpty
                    ? AtelierTheme.roleEmoji(for: role.name, fallback: "•")
                    : role.emoji
                Text("\(emoji) \(role.name)")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? AtelierTheme.roleColor(for: role.name).opacity(0.30)
                                : AtelierTheme.panel)
            .overlay(Capsule().stroke(
                selected ? AtelierTheme.roleColor(for: role.name) : AtelierTheme.border,
                lineWidth: selected ? 1.2 : 1))
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
                    .font(.caption).foregroundStyle(AtelierTheme.dim).lineLimit(1)
                Spacer()
                Circle()
                    .fill(session.alive ? Color.green : Color.gray)
                    .frame(width: 6, height: 6)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(AtelierTheme.dim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AtelierTheme.panel)
            Divider().overlay(AtelierTheme.border)
            PtyTerminalView(session: session)
                .frame(minHeight: 220)
                .clipped()
        }
        .background(AtelierTheme.cell)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AtelierTheme.border))
    }

    private var roleBadge: some View {
        let name = session.roleName ?? "terminal"
        let color = AtelierTheme.roleColor(for: name)
        let emoji = AtelierTheme.roleEmoji(for: name, fallback: session.roleEmoji ?? "")
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
