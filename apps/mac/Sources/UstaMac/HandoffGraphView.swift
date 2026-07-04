import SwiftUI
import UstaProto

/// Live handoff graph — the team as an animated DAG.
/// Nodes are roles (colored by state), edges are handoff topics, and each
/// recent bus event fires a pulse traveling down its edge. This is the
/// 10-second answer to "why is this not just tmux": you can SEE the
/// orchestration.
struct HandoffGraphView: View {
    let roles: [Usta_V1_Role]
    @EnvironmentObject var bus: WorkspaceBus

    /// role → node layout position (grid: column = topo layer).
    private struct Node: Identifiable {
        let id: String        // role name
        let emoji: String
        let layer: Int
        let row: Int
        var pos: CGPoint = .zero
    }

    private struct Edge: Identifiable {
        let id: String        // "from→to:topic"
        let from: String
        let to: String
        let topic: String
    }

    var body: some View {
        GeometryReader { geo in
            // Layout + active-edge lookup computed HERE — i.e. only when the
            // view re-evaluates (roles/bus/size change), NOT on every
            // animation tick. Keeping this inside the TimelineView closure
            // recomputed the whole graph 30×/s and janked the entire app.
            let (nodes, edges) = layout(in: geo.size)
            let pos = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.pos) })
            let activeEdges = activeEdgeIds(edges)
            ZStack {
                // Static layer: nodes never need per-frame invalidation.
                edgeCanvas(edges: edges, pos: pos, activeEdges: activeEdges)
                ForEach(nodes) { n in
                    nodeView(n)
                        .position(n.pos)
                }
            }
        }
        .background(UstaTheme.bg)
        .overlay(alignment: .bottomLeading) { legend.padding(10) }
    }

    /// Edge layer. Animates at 24fps ONLY while a pulse is in flight;
    /// otherwise the TimelineView is paused and this is a one-shot draw.
    private func edgeCanvas(edges: [Edge], pos: [String: CGPoint], activeEdges: Set<String>) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: activeEdges.isEmpty)) { timeline in
            let now = timeline.date.timeIntervalSince1970
            Canvas { ctx, _ in
                for e in edges {
                    guard let a = pos[e.from], let b = pos[e.to] else { continue }
                    let path = curve(from: a, to: b)
                    let isActive = activeEdges.contains(e.id)
                    ctx.stroke(path,
                               with: .color(isActive
                                            ? UstaTheme.accentTeal.opacity(0.9)
                                            : UstaTheme.border.opacity(0.9)),
                               style: StrokeStyle(lineWidth: isActive ? 2 : 1.2))
                    // Arrowhead near the target
                    let tip = point(on: (a, b), t: 0.92)
                    let dirP = point(on: (a, b), t: 0.86)
                    ctx.fill(arrowhead(at: tip, from: dirP),
                             with: .color(isActive ? UstaTheme.accentTeal : UstaTheme.dim2))
                    // Pulse dot animating along the curve
                    if isActive {
                        let phase = CGFloat((now / 1.6).truncatingRemainder(dividingBy: 1.0))
                        let p = point(on: (a, b), t: phase)
                        let r: CGFloat = 5
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                                 with: .color(UstaTheme.accentTeal))
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4)),
                                 with: .color(UstaTheme.accentTeal.opacity(0.25)))
                    }
                }
            }
        }
    }

    /// Edges whose topic fired on the bus in the last 45s. Recomputed only
    /// when bus.events changes.
    private func activeEdgeIds(_ edges: [Edge]) -> Set<String> {
        let cutoff = Int64((Date().timeIntervalSince1970 - 45) * 1000)
        var lastByKey: [String: Int64] = [:]
        for ev in bus.events where ev.createdUnixMs >= cutoff {
            lastByKey["\(ev.fromRole)|\(ev.topic)"] = ev.createdUnixMs
        }
        guard !lastByKey.isEmpty else { return [] }
        return Set(edges.filter { lastByKey["\($0.from)|\($0.topic)"] != nil }.map(\.id))
    }

    // MARK: node view

    private func nodeView(_ n: Node) -> some View {
        let state = bus.state(of: n.id)
        let color = stateColor(state)
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(UstaTheme.cell)
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .frame(width: 46, height: 46)
                Text(n.emoji.isEmpty ? "🤖" : n.emoji).font(.system(size: 20))
                if state == .working {
                    Circle()
                        .stroke(color.opacity(0.5), lineWidth: 2)
                        .frame(width: 56, height: 56)
                }
            }
            Text("@\(n.id)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(stateLabel(state))
                .font(.system(size: 8, weight: .medium))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.18))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
        .onTapGesture {
            NotificationCenter.default.post(name: .ustaFocusRole, object: n.id)
        }
        .help("Open @\(n.id)")
    }

    private func stateColor(_ s: WorkspaceBus.RoleState) -> Color {
        switch s {
        case .done:    return UstaTheme.accentTeal
        case .working: return UstaTheme.accentPink
        case .ready:   return UstaTheme.accentAmber
        default:       return UstaTheme.dim2
        }
    }

    private func stateLabel(_ s: WorkspaceBus.RoleState) -> String {
        switch s {
        case .done: return "done"
        case .working: return "working"
        case .ready: return "ready"
        default: return "waiting"
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([("done", UstaTheme.accentTeal), ("working", UstaTheme.accentPink),
                     ("ready", UstaTheme.accentAmber), ("waiting", UstaTheme.dim2)], id: \.0) { pair in
                HStack(spacing: 4) {
                    Circle().fill(pair.1).frame(width: 7, height: 7)
                    Text(pair.0).font(.system(size: 9)).foregroundStyle(UstaTheme.dim)
                }
            }
            Text("· pulse = handoff on the bus (last 45s)")
                .font(.system(size: 9)).foregroundStyle(UstaTheme.dim2)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(UstaTheme.panel.opacity(0.9))
        .clipShape(Capsule())
    }

    // MARK: geometry

    private func curve(from a: CGPoint, to b: CGPoint) -> Path {
        var p = Path()
        p.move(to: a)
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let bend: CGFloat = a.y == b.y ? 24 : 0
        p.addQuadCurve(to: b, control: CGPoint(x: mid.x, y: mid.y - bend))
        return p
    }

    /// Point along the same quad curve at parameter t.
    private func point(on seg: (CGPoint, CGPoint), t: CGFloat) -> CGPoint {
        let (a, b) = seg
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let bend: CGFloat = a.y == b.y ? 24 : 0
        let c = CGPoint(x: mid.x, y: mid.y - bend)
        let u = 1 - t
        let x = u * u * a.x + 2 * u * t * c.x + t * t * b.x
        let y = u * u * a.y + 2 * u * t * c.y + t * t * b.y
        return CGPoint(x: x, y: y)
    }

    private func arrowhead(at tip: CGPoint, from back: CGPoint) -> Path {
        let angle = atan2(tip.y - back.y, tip.x - back.x)
        let len: CGFloat = 7
        var p = Path()
        p.move(to: tip)
        p.addLine(to: CGPoint(x: tip.x - len * cos(angle - 0.45), y: tip.y - len * sin(angle - 0.45)))
        p.addLine(to: CGPoint(x: tip.x - len * cos(angle + 0.45), y: tip.y - len * sin(angle + 0.45)))
        p.closeSubpath()
        return p
    }

    // MARK: layout (topo layers → columns)

    private func layout(in size: CGSize) -> ([Node], [Edge]) {
        // Build edges from declared topics: producer → subscriber.
        var edges: [Edge] = []
        for producer in roles {
            for topic in producer.handoffPublishes {
                for consumer in roles where consumer.name != producer.name
                    && consumer.handoffSubscribes.contains(topic) {
                    edges.append(Edge(id: "\(producer.name)→\(consumer.name):\(topic)",
                                      from: producer.name, to: consumer.name, topic: topic))
                }
            }
        }
        // Longest-path layering (cycle-guarded by iteration cap).
        var layer: [String: Int] = [:]
        for r in roles { layer[r.name] = 0 }
        for _ in 0..<(roles.count + 1) {
            var changed = false
            for e in edges {
                let want = (layer[e.from] ?? 0) + 1
                if want > (layer[e.to] ?? 0) && want <= roles.count {
                    layer[e.to] = want
                    changed = true
                }
            }
            if !changed { break }
        }
        // Group by layer → columns; rows spread evenly.
        let maxLayer = layer.values.max() ?? 0
        var byLayer: [Int: [Usta_V1_Role]] = [:]
        for r in roles { byLayer[layer[r.name] ?? 0, default: []].append(r) }
        let colW = size.width / CGFloat(maxLayer + 1)
        var nodes: [Node] = []
        for (l, group) in byLayer {
            let sorted = group.sorted { $0.name < $1.name }
            let rowH = size.height / CGFloat(sorted.count + 1)
            for (i, r) in sorted.enumerated() {
                var n = Node(id: r.name, emoji: r.emoji, layer: l, row: i)
                n.pos = CGPoint(x: colW * (CGFloat(l) + 0.5),
                                y: rowH * CGFloat(i + 1))
                nodes.append(n)
            }
        }
        return (nodes, edges)
    }
}
