import SwiftUI
import UstaProto

/// Grid of Claude-Code-style assistant panes — one per workspace role.
/// Responsive: cols computed from available width. Each pane can be
/// collapsed to a header strip.
struct AssistantsGrid: View {
    let workspaceID: String
    let roles: [Usta_V1_Role]
    /// When non-nil, only this role is shown (focused/expanded).
    let focus: String?

    @State private var collapsed: Set<String> = []
    @State private var maximized: String? = nil
    @EnvironmentObject var bus: WorkspaceBus
    /// Called by AssistantPane's maximize button when grid is already in
    /// single-pane mode (filtered by chip). Lets ContentView clear its
    /// `selectedRole` so user lands back on All.
    var onClearFocus: (() -> Void)? = nil

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
        // CRITICAL: always render ALL roles. Filtering `shown` per focus
        // tore down ChatPanes (and their SwiftTerm Metal layers) on every
        // chip toggle, then re-allocated them on focus-clear. That was the
        // real chip-switch lag.
        //
        // Now we pass `roles` (full list) to the grid unconditionally.
        // Hidden roles get frame(height: 0) + opacity(0) so SwiftUI keeps
        // their ChatPane mounted but they don't take layout space.
        Group {
            if roles.isEmpty {
                empty
            } else {
                grid(roles)
            }
        }
        .onChange(of: focus) { _, _ in reconcileMaximize() }
    }

    /// Visible role(s) for the current focus / maximize state.
    private var visibleNames: Set<String> {
        if let m = maximized { return [m] }
        if let f = focus     { return [f] }
        return Set(roles.map { $0.name })   // All
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

    private func grid(_ shown: [Usta_V1_Role]) -> some View {
        // Use canonical bus ordering (working > ready > bottleneck > pending > done).
        let ordered = bus.orderedRoles(shown)
        let displayStep: [String: Int] = Dictionary(uniqueKeysWithValues:
            ordered.enumerated().map { ($1.name, $0 + 1) }
        )
        let visible = visibleNames
        let visibleCount = ordered.filter { visible.contains($0.name) }.count
        let singleFocus = visibleCount == 1
        return GeometryReader { geo in
            // Column count based on visible pane count, not total (so a
            // single focused role gets a full-width pane).
            let n = cols(for: geo.size.width, count: max(1, visibleCount))
            // In single-focus mode let the focused pane fill the whole grid
            // height (no scrolling). In All mode the scrollview lets a tall
            // list overflow.
            let visibleMinHeight: CGFloat = singleFocus
                ? max(360, geo.size.height - 20)
                : 360
            ScrollView {
                // Truly NON-lazy fixed-column layout. LazyVGrid's placement
                // machinery hard-looped twice (100% CPU in
                // LazySubviewPlacements.placeSubviews) with this pane set —
                // and laziness bought nothing anyway, since hidden panes stay
                // in the tree to keep SwiftTerm views alive. A dumb
                // deterministic Layout cannot loop.
                FixedColumnsLayout(columns: n, spacing: 8) {
                    ForEach(ordered, id: \.name) { role in
                        let isVisible = visible.contains(role.name)
                        AssistantPane(
                            workspaceID: workspaceID,
                            role: role,
                            collapsed: collapsed.contains(role.name),
                            onToggleCollapse: { toggle(role.name) },
                            isMaximized: maximized == role.name || (focus == role.name && visibleCount == 1),
                            onToggleMaximize: {
                                if focus == role.name && visibleCount == 1 {
                                    maximized = nil
                                    onClearFocus?()
                                } else {
                                    toggleMax(role.name)
                                }
                            },
                            // Render the heavy SwiftTerm view only where it
                            // matters: the sole focused/maximized pane, a pane
                            // actively WORKING, or the role that's up NEXT (so
                            // the one about to run stays awake). Everything else
                            // sleeps — PTYs keep running + buffering, so opening
                            // catches up instantly. Keeps a busy grid fast.
                            live: (isVisible && visibleCount == 1)
                                || bus.state(of: role.name) == .working
                                || bus.pinnedBottleneckName == role.name
                                || bus.readyNow.first == role.name,
                            step: displayStep[role.name],
                            stateColor: stateColor(bus.state(of: role.name))
                        )
                        // FINITE heights only. `maxHeight: .infinity` inside a
                        // lazy container in a ScrollView made SwiftUI's lazy
                        // placement never converge — the app hard-froze at
                        // 100% CPU in LazySubviewPlacements.placeSubviews.
                        .frame(height: isVisible
                                ? (collapsed.contains(role.name) ? 56 : visibleMinHeight)
                                : 0)
                        .opacity(isVisible ? 1 : 0)
                        .allowsHitTesting(isVisible)
                        .background(UstaTheme.cell)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(UstaTheme.roleColor(for: role.name).opacity(0.35))
                        )
                    }
                }
                .padding(10)
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
                .foregroundStyle(UstaTheme.dim2)
            Text("No assistants yet.").foregroundStyle(UstaTheme.dim)
            Text("Run Apply Team to let the PM build a project team.")
                .font(.caption).foregroundStyle(UstaTheme.dim2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dead-simple fixed-column grid. Non-lazy on purpose: every subview is
/// measured once per pass with a concrete width, placed left-to-right,
/// wrapped every `columns` items. Zero-height subviews (hidden panes) are
/// parked at the origin and skipped, so they neither consume a cell nor
/// add row spacing. No caches, no feedback — layout always converges.
struct FixedColumnsLayout: Layout {
    var columns: Int
    var spacing: CGFloat = 8

    private func colWidth(_ total: CGFloat) -> CGFloat {
        max(50, (total - spacing * CGFloat(columns - 1)) / CGFloat(columns))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 800
        let colW = colWidth(width)
        var y: CGFloat = 0, rowH: CGFloat = 0, col = 0, placedAny = false
        for v in subviews {
            let h = v.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            if h <= 0.5 { continue }
            placedAny = true
            rowH = max(rowH, h)
            col += 1
            if col == columns { y += rowH + spacing; rowH = 0; col = 0 }
        }
        if col > 0 { y += rowH }
        else if placedAny { y -= spacing }
        return CGSize(width: width, height: max(0, y))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let colW = colWidth(bounds.width)
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0, col = 0
        for v in subviews {
            let h = v.sizeThatFits(ProposedViewSize(width: colW, height: nil)).height
            if h <= 0.5 {
                // Hidden pane: keep it in the tree (SwiftTerm view survives)
                // but give it no cell.
                v.place(at: CGPoint(x: bounds.minX, y: bounds.minY),
                        proposal: ProposedViewSize(width: 0, height: 0))
                continue
            }
            v.place(at: CGPoint(x: x, y: y),
                    proposal: ProposedViewSize(width: colW, height: h))
            rowH = max(rowH, h)
            col += 1
            if col == columns {
                col = 0; x = bounds.minX; y += rowH + spacing; rowH = 0
            } else {
                x += colW + spacing
            }
        }
    }
}
