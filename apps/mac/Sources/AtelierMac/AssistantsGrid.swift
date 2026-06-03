import SwiftUI
import AtelierProto

/// Grid of Claude-Code-style assistant panes — one per workspace role.
/// Responsive: cols computed from available width. Each pane can be
/// collapsed to a header strip.
struct AssistantsGrid: View {
    let workspaceID: String
    let roles: [Atelier_V1_Role]
    /// When non-nil, only this role is shown (focused/expanded).
    let focus: String?

    @State private var collapsed: Set<String> = []
    @State private var maximized: String? = nil
    @EnvironmentObject var bus: WorkspaceBus

    // Drop a stale maximize when the user filters to a different role / All.
    private func reconcileMaximize() {
        guard let m = maximized else { return }
        if let f = focus, m != f { maximized = nil }
        if focus == nil && !roles.contains(where: { $0.name == m }) { maximized = nil }
    }

    /// Map role.name -> 1-based step tier from topo sort over handoff topics.
    /// Roles with no upstream = step 1, downstream tiers increment.
    private var stepFor: [String: Int] {
        var producers: [String: Set<String>] = [:]
        for r in roles {
            for t in r.handoffPublishes {
                producers[t, default: []].insert(r.name)
            }
        }
        var upstream: [String: Set<String>] = [:]
        for r in roles {
            var deps: Set<String> = []
            for t in r.handoffSubscribes {
                if let pubs = producers[t] {
                    for p in pubs where p != r.name { deps.insert(p) }
                }
            }
            upstream[r.name] = deps
        }
        var step: [String: Int] = [:]
        var remaining = roles
        var tier = 1
        while !remaining.isEmpty {
            let ready = remaining.filter { r in
                (upstream[r.name] ?? []).allSatisfy { step[$0] != nil }
            }
            if ready.isEmpty {
                for r in remaining { step[r.name] = tier }
                break
            }
            for r in ready { step[r.name] = tier }
            let names = Set(ready.map { $0.name })
            remaining.removeAll { names.contains($0.name) }
            tier += 1
        }
        return step
    }

    var body: some View {
        let baseShown = focus == nil ? roles : roles.filter { $0.name == focus }
        // Maximize works in any view (All or focused). When user navigates
        // to a chip with a different role, ContentView clears `selectedRole`
        // and we honour `maximized` directly here.
        let shown: [Atelier_V1_Role] = {
            if let m = maximized, let r = baseShown.first(where: { $0.name == m }) { return [r] }
            return baseShown
        }()
        let steps = stepFor
        Group {
            if shown.isEmpty {
                empty
            } else if shown.count == 1 {
                AssistantPane(
                    workspaceID: workspaceID,
                    role: shown[0],
                    collapsed: collapsed.contains(shown[0].name),
                    onToggleCollapse: { toggle(shown[0].name) },
                    isMaximized: maximized == shown[0].name,
                    onToggleMaximize: { toggleMax(shown[0].name) },
                    step: 1,
                    stateColor: stateColor(bus.state(of: shown[0].name))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AtelierTheme.cell)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AtelierTheme.roleColor(for: shown[0].name).opacity(0.35))
                )
                .padding(10)
            } else {
                grid(shown)
            }
        }
        .onChange(of: focus) { _, _ in reconcileMaximize() }
    }

    /// Compute column count from available width with a min pane width.
    /// Each pane needs ~440px to render its full header without overflow.
    private func cols(for width: CGFloat, count: Int) -> Int {
        let minPane: CGFloat = 440
        let spacing: CGFloat = 8
        // (n * minPane) + ((n-1) * spacing) + 20 padding <= width
        // n <= (width - 20 + spacing) / (minPane + spacing)
        let usable = max(0, width - 20)
        let n = Int((usable + spacing) / (minPane + spacing))
        return max(1, min(n == 0 ? 1 : n, count))
    }

    /// Lower number = higher visual priority.
    private func priority(_ s: WorkspaceBus.RoleState) -> Int {
        switch s {
        case .working: return 0   // currently doing work — surface first
        case .ready:   return 1   // user attention next
        case .pending: return 2
        case .done:    return 3   // finished — bottom
        }
    }

    private func grid(_ shown: [Atelier_V1_Role]) -> some View {
        // Use canonical bus ordering (working > ready > bottleneck > pending > done).
        let ordered = bus.orderedRoles(shown)
        let displayStep: [String: Int] = Dictionary(uniqueKeysWithValues:
            ordered.enumerated().map { ($1.name, $0 + 1) }
        )
        return GeometryReader { geo in
            let n = cols(for: geo.size.width, count: shown.count)
            let layout = Array(repeating: GridItem(.flexible(minimum: 380), spacing: 8), count: n)
            ScrollView {
                LazyVGrid(columns: layout, spacing: 8) {
                    ForEach(ordered, id: \.name) { role in
                        AssistantPane(
                            workspaceID: workspaceID,
                            role: role,
                            collapsed: collapsed.contains(role.name),
                            onToggleCollapse: { toggle(role.name) },
                            isMaximized: maximized == role.name,
                            onToggleMaximize: { toggleMax(role.name) },
                            step: displayStep[role.name],
                            stateColor: stateColor(bus.state(of: role.name))
                        )
                        .frame(minHeight: collapsed.contains(role.name) ? 56 : 360)
                        .background(AtelierTheme.cell)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AtelierTheme.roleColor(for: role.name).opacity(0.35))
                        )
                    }
                }
                .padding(10)
                .animation(.easeInOut(duration: 0.35), value: ordered.map(\.name))
            }
        }
    }

    private func toggle(_ name: String) {
        if collapsed.contains(name) { collapsed.remove(name) } else { collapsed.insert(name) }
    }

    private func toggleMax(_ name: String) {
        if maximized == name { maximized = nil } else { maximized = name }
    }

    private func stateColor(_ s: WorkspaceBus.RoleState) -> Color {
        switch s {
        case .pending: return .gray
        case .ready:   return .blue
        case .working: return .orange
        case .done:    return .green
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.sequence").font(.system(size: 38))
                .foregroundStyle(AtelierTheme.dim2)
            Text("No assistants yet.").foregroundStyle(AtelierTheme.dim)
            Text("Run Apply Team to let the PM build a project team.")
                .font(.caption).foregroundStyle(AtelierTheme.dim2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
