import SwiftUI
import AppKit
import AtelierProto

struct ContentView: View {
    @EnvironmentObject var client: AtelierClientModel
    @State private var selection: Atelier_V1_Workspace?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await openFolder() }
                } label: {
                    Label("Open Project", systemImage: "folder.badge.plus")
                }
                Button {
                    Task { await client.refreshWorkspaces() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .navigationTitle("Atelier")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusHeader
            Divider()
            List(selection: $selection) {
                Section("Workspaces") {
                    if client.workspaces.isEmpty {
                        Text("No projects yet — open a folder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(client.workspaces, id: \.id) { ws in
                        WorkspaceRow(ws: ws)
                            .tag(ws)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 240)
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(client.connected ? "daemon online" : "daemon offline")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let v = client.daemonVersion {
                Text("v\(v)").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var detail: some View {
        if let ws = selection {
            WorkspaceDetailView(ws: ws)
        } else {
            VStack(spacing: 14) {
                Image(systemName: "rectangle.3.group.bubble")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Open or select a project to begin.")
                    .foregroundStyle(.secondary)
                if let err = client.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openFolder() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Project"
        if panel.runModal() == .OK, let url = panel.url {
            await client.openWorkspace(path: url.path)
        }
    }
}

struct WorkspaceRow: View {
    let ws: Atelier_V1_Workspace
    var body: some View {
        HStack {
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name).font(.body)
                Text(ws.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct WorkspaceDetailView: View {
    let ws: Atelier_V1_Workspace
    @EnvironmentObject var client: AtelierClientModel
    @StateObject private var grid = TerminalGridModel()
    @State private var roles: [Atelier_V1_Role] = []
    @State private var selectedRole: Atelier_V1_Role? = nil
    @State private var showApplyTeam = false
    @State private var applyInFlight = false
    @State private var applyResult: String? = nil

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Divider()
                if grid.sessions.isEmpty {
                    empty
                } else {
                    terminals
                }
            }
            .frame(maxWidth: .infinity)
            if let role = selectedRole {
                Divider()
                ChatPane(workspaceID: ws.id, role: role)
                    .frame(minWidth: 380, idealWidth: 440)
            }
        }
        .task(id: ws.id) {
            await grid.load(workspaceID: ws.id, client: client)
            roles = await client.listRoles(workspaceID: ws.id)
        }
        .sheet(isPresented: $showApplyTeam) { applyTeamSheet }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.fill.badge.gear")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text(ws.name).font(.title3.bold())
                    Text(ws.path).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).lineLimit(1)
                }
                Spacer()
                Button {
                    showApplyTeam = true
                } label: {
                    Label("Apply Team", systemImage: "person.3.sequence")
                }
                Button {
                    Task { await grid.newTerminal(workspaceID: ws.id, client: client) }
                } label: {
                    Label("New Terminal", systemImage: "plus.rectangle")
                }
            }
            if !roles.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(roles, id: \.name) { r in
                            roleChip(r)
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func roleChip(_ r: Atelier_V1_Role) -> some View {
        let selected = selectedRole?.name == r.name
        return Button {
            if selected { selectedRole = nil } else { selectedRole = r }
        } label: {
            HStack(spacing: 4) {
                Text(r.emoji)
                Text(r.name).font(.caption.weight(.medium))
                scopeBadge(for: r.scope)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func scopeBadge(for scope: String) -> some View {
        switch scope {
        case "workspace":
            Text("ws").font(.system(size: 9)).foregroundStyle(.orange)
        case "user":
            Text("user").font(.system(size: 9)).foregroundStyle(.cyan)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var applyTeamSheet: some View {
        VStack(spacing: 16) {
            Text("Apply Team").font(.title2.bold())
            Text("Atelier will analyze \(ws.name) and write a custom team to .atelier/roles/.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
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

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal").font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("No terminals open in this workspace.").foregroundStyle(.secondary)
            Button("Open the first one") {
                Task { await grid.newTerminal(workspaceID: ws.id, client: client) }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var terminals: some View {
        let cols = max(1, min(grid.sessions.count, 2))
        let layout = Array(repeating: GridItem(.flexible(), spacing: 6), count: cols)
        return LazyVGrid(columns: layout, spacing: 6) {
            ForEach(grid.sessions) { session in
                TerminalCell(session: session) {
                    Task { await grid.closeTerminal(id: session.id, client: client) }
                }
            }
        }
        .padding(6)
    }
}

struct TerminalCell: View {
    @ObservedObject var session: TerminalSession
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle()
                    .fill(session.alive ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(session.title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.thinMaterial)
            PtyTerminalView(session: session)
                .frame(minHeight: 220)
                .clipped()
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2))
        )
    }
}
