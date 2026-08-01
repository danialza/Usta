import SwiftUI
import AppKit
import UstaProto

/// ⌘K palette: semantic search across the workspace's code plus quick
/// actions. The embedding index behind it has existed in the daemon since
/// day one with no way to reach it — this is that door.
struct CommandPalette: View {
    let workspaceID: String
    let workspacePath: String
    let roles: [Usta_V1_Role]
    /// Focus a role pane (same notification the graph/activity feed use).
    var onOpenRole: (String) -> Void
    var onAction: (PaletteAction) -> Void

    @EnvironmentObject var client: UstaClientModel
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var hits: [Usta_V1_SearchHit] = []
    @State private var searching = false
    @State private var selected = 0
    @State private var indexing = false
    @State private var indexStatus = ""
    @FocusState private var focused: Bool
    /// Debounce token — only the newest keystroke's search is applied.
    @State private var searchGeneration = 0

    enum PaletteAction: String, CaseIterable {
        case startTeam, costs, replay, graph, newFeature, reindex
        var title: String {
            switch self {
            case .startTeam:  return "Start Team"
            case .costs:      return "Show costs"
            case .replay:     return "Session replay"
            case .graph:      return "Handoff graph"
            case .newFeature: return "New feature or change…"
            case .reindex:    return "Re-index this workspace"
            }
        }
        var icon: String {
            switch self {
            case .startTeam:  return "play.fill"
            case .costs:      return "dollarsign.circle"
            case .replay:     return "memories"
            case .graph:      return "point.3.connected.trianglepath.dotted"
            case .newFeature: return "lightbulb.fill"
            case .reindex:    return "arrow.clockwise"
            }
        }
    }

    /// Rows are actions + roles when the query is short, code hits once the
    /// user has typed enough for the embedding search to mean anything.
    private var matchedActions: [PaletteAction] {
        guard !query.isEmpty else { return PaletteAction.allCases }
        return PaletteAction.allCases.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }
    private var matchedRoles: [Usta_V1_Role] {
        guard !query.isEmpty else { return [] }
        let q = query.hasPrefix("@") ? String(query.dropFirst()) : query
        return roles.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var totalRows: Int { matchedActions.count + matchedRoles.count + hits.count }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(UstaTheme.border)
            if totalRows == 0 {
                emptyState
            } else {
                results
            }
            Divider().overlay(UstaTheme.border)
            footer
        }
        .frame(width: 660, height: 460)
        .background(UstaTheme.panel)
        .onAppear { focused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: searching ? "ellipsis" : "magnifyingglass")
                .foregroundStyle(UstaTheme.dim)
                .symbolEffect(.pulse, isActive: searching)
            TextField("Search code, roles, or actions…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($focused)
                .onSubmit { activate(selected) }
                .onChange(of: query) { _, q in
                    selected = 0
                    scheduleSearch(q)
                }
            if !query.isEmpty {
                Button { query = ""; hits = [] } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(UstaTheme.dim)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(UstaTheme.dim2)
            Text(indexing ? indexStatus : "No matches")
                .font(.system(size: 12)).foregroundStyle(UstaTheme.dim)
            if !indexing && !query.isEmpty {
                Text("Code search needs an index — run “Re-index this workspace”.")
                    .font(.system(size: 11)).foregroundStyle(UstaTheme.dim2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    var row = 0
                    if !matchedActions.isEmpty {
                        sectionHeader("Actions")
                        ForEach(Array(matchedActions.enumerated()), id: \.element) { _, a in
                            let idx = indexOfAction(a)
                            paletteRow(icon: a.icon, title: a.title, subtitle: nil, index: idx)
                                .id(idx)
                        }
                    }
                    if !matchedRoles.isEmpty {
                        sectionHeader("Roles")
                        ForEach(Array(matchedRoles.enumerated()), id: \.element.name) { i, r in
                            let idx = matchedActions.count + i
                            paletteRow(icon: "person.fill", title: "@\(r.name)",
                                       subtitle: r.description_p, index: idx,
                                       tint: UstaTheme.roleColor(for: r.name))
                                .id(idx)
                        }
                    }
                    if !hits.isEmpty {
                        sectionHeader("Code")
                        ForEach(Array(hits.enumerated()), id: \.offset) { i, h in
                            let idx = matchedActions.count + matchedRoles.count + i
                            codeRow(h, index: idx).id(idx)
                        }
                    }
                    let _ = row
                }
                .padding(.vertical, 6)
            }
            .onChange(of: selected) { _, s in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(s, anchor: .center) }
            }
        }
    }

    private func sectionHeader(_ s: String) -> some View {
        HStack {
            Text(s.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1)
                .foregroundStyle(UstaTheme.dim2)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 2)
    }

    private func paletteRow(icon: String, title: String, subtitle: String?,
                            index: Int, tint: Color = UstaTheme.accentTeal) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(UstaTheme.dim)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(index == selected ? tint.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { activate(index) }
    }

    private func codeRow(_ h: Usta_V1_SearchHit, index: Int) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text").font(.system(size: 13))
                .foregroundStyle(UstaTheme.accentPurple).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shortPath(h.path))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                    Text("\(h.startLine)–\(h.endLine)")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(UstaTheme.dim2)
                }
                Text(h.snippet.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(UstaTheme.dim)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(index == selected ? UstaTheme.accentPurple.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { activate(index) }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            key("↑↓", "navigate"); key("↩", "open"); key("esc", "close")
            Spacer()
            if indexing {
                HStack(spacing: 5) {
                    ProgressView().scaleEffect(0.4)
                    Text(indexStatus).font(.system(size: 10)).foregroundStyle(UstaTheme.dim)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func key(_ k: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(k).font(.system(size: 9, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(UstaTheme.cell).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 10)).foregroundStyle(UstaTheme.dim2)
        }
    }

    // MARK: behaviour

    private func indexOfAction(_ a: PaletteAction) -> Int {
        matchedActions.firstIndex(of: a) ?? 0
    }

    private func shortPath(_ p: String) -> String {
        let rel = p.hasPrefix(workspacePath)
            ? String(p.dropFirst(workspacePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            : p
        return rel.isEmpty ? (p as NSString).lastPathComponent : rel
    }

    /// Debounced semantic search — embedding a query per keystroke would
    /// hammer the daemon, so wait for a pause and drop stale results.
    private func scheduleSearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { hits = []; return }
        searchGeneration += 1
        let gen = searchGeneration
        Task {
            try? await Task.sleep(nanoseconds: 260_000_000)
            guard gen == searchGeneration else { return }
            searching = true
            let r = await client.searchWorkspace(workspaceID: workspaceID, query: trimmed)
            guard gen == searchGeneration else { return }
            hits = r
            searching = false
        }
    }

    private func activate(_ index: Int) {
        let a = matchedActions.count, rl = matchedRoles.count
        if index < a {
            let act = matchedActions[index]
            if act == .reindex { reindex(); return }
            onAction(act); dismiss()
        } else if index < a + rl {
            onOpenRole(matchedRoles[index - a].name); dismiss()
        } else {
            let h = hits[index - a - rl]
            // Reveal in Finder rather than guessing an editor: works with
            // whatever the user actually uses.
            NSWorkspace.shared.selectFile(h.path, inFileViewerRootedAtPath: workspacePath)
            dismiss()
        }
    }

    private func reindex() {
        guard !indexing else { return }
        indexing = true
        indexStatus = "indexing…"
        Task {
            await client.indexWorkspace(workspaceID: workspaceID) { files, chunks, done in
                indexStatus = done ? "indexed \(files) files · \(chunks) chunks"
                                   : "indexing \(files) files…"
                if done { indexing = false }
            }
            indexing = false
            // Re-run the pending query now that there's something to hit.
            if !query.isEmpty { scheduleSearch(query) }
        }
    }
}

/// Arrow-key handling for the palette. SwiftUI's TextField swallows arrows,
/// so intercept them at the NSEvent level while the sheet is up.
struct PaletteKeyHandler: NSViewRepresentable {
    var onUp: () -> Void
    var onDown: () -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
            switch ev.keyCode {
            case 126: onUp(); return nil     // ↑
            case 125: onDown(); return nil   // ↓
            default: return ev
            }
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }
    final class Coordinator { var monitor: Any? }
}
