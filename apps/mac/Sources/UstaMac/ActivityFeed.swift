import SwiftUI
import UstaProto

/// Inter-agent activity panel. Driven by shared WorkspaceBus.
/// - Top banner: "Next ready: @role1, @role2" (or "All idle / done")
/// - Each event row: from-role + topic + subscribers (auto-dispatch fan-out)
/// - Fresh events highlighted with system color for ~6s
struct ActivityFeed: View {
    let workspaceID: String
    @EnvironmentObject var bus: WorkspaceBus

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(UstaTheme.border)
            nextBanner
            Divider().overlay(UstaTheme.border)
            if bus.events.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(bus.events.reversed(), id: \.id) { e in
                            eventRow(e)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(UstaTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
            Text("Team Activity").font(.headline)
            Spacer()
            Text("\(bus.events.count)").font(.caption2).foregroundStyle(UstaTheme.dim)
        }
        .padding(10)
    }

    private var nextBanner: some View {
        let ready = bus.readyNow
        let working = bus.roles.first(where: { bus.state(of: $0.name) == .working })?.name
        let allDone = !bus.roles.isEmpty && bus.roles.allSatisfy { bus.state(of: $0.name) == .done }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: headerIcon(ready: ready, working: working, allDone: allDone))
                    .foregroundStyle(headerColor(ready: ready, working: working, allDone: allDone))
                Text(headerTitle(ready: ready, working: working, allDone: allDone))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(UstaTheme.dim)
                Spacer()
            }
            if let w = working {
                Text("@\(w) is running. Open its pane to watch.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if !ready.isEmpty {
                ForEach(ready, id: \.self) { name in
                    readyRow(name)
                }
            } else if allDone {
                Text("All roles finished. Project at a clean checkpoint.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let bn = bus.bottleneck() {
                bottleneckRow(bn)
            } else {
                Text("No role waiting on a fresh event")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(UstaTheme.cell.opacity(0.4))
    }

    private func headerIcon(ready: [String], working: String?, allDone: Bool) -> String {
        if working != nil { return "clock.arrow.circlepath" }
        if !ready.isEmpty { return "arrow.right.circle.fill" }
        if allDone { return "checkmark.circle.fill" }
        if bus.bottleneck()?.cycle == true { return "arrow.triangle.2.circlepath" }
        return "hand.point.right.fill"
    }
    private func headerColor(ready: [String], working: String?, allDone: Bool) -> Color {
        if working != nil { return .orange }
        if !ready.isEmpty { return Color.accentColor }
        if allDone { return .green }
        return .yellow
    }
    private func headerTitle(ready: [String], working: String?, allDone: Bool) -> String {
        if working != nil { return "Working" }
        if !ready.isEmpty { return "Next ready" }
        if allDone { return "All done" }
        if bus.bottleneck()?.cycle == true { return "Cycle — break it" }
        return "Unblock"
    }

    private func bottleneckRow(_ bn: (name: String, dependents: Int, cycle: Bool)) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(UstaTheme.roleColor(for: bn.name)).frame(width: 6, height: 6)
                Text("@\(bn.name)").font(.system(size: 12, weight: .semibold))
                Text("blocks \(bn.dependents)").font(.system(size: 9))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.yellow.opacity(0.25))
                    .clipShape(Capsule())
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .ustaAutoRegenerate, object: bn.name)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text("Gen").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Generate a fresh prompt for @\(bn.name)")
            }
            Text(bn.cycle
                 ? "Cycle: every pending role waits on another. Open @\(bn.name), Generate, Send."
                 : "Open @\(bn.name), Generate prompt, Send to unblock downstream roles.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readyRow(_ name: String) -> some View {
        let conflicts = bus.conflicts(with: name)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(UstaTheme.roleColor(for: name)).frame(width: 6, height: 6)
                Text("@\(name)").font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .ustaKickoffRole, object: name)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(.system(size: 9))
                        Text("Run").font(.system(size: 10, weight: .medium))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(conflicts.isEmpty ? Color.accentColor : Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(conflicts.isEmpty ? "Send kickoff to @\(name)" : "May conflict with \(conflicts.map { "@\($0)" }.joined(separator: ", "))")
            }
            if !conflicts.isEmpty {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8)).foregroundStyle(.orange)
                    Text("may conflict with \(conflicts.map { "@\($0)" }.joined(separator: ", "))")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(UstaTheme.dim2)
            Text("No handoffs yet.").font(.caption).foregroundStyle(UstaTheme.dim)
            Text("When an assistant publishes an event, it appears here and downstream roles auto-react.")
                .font(.system(size: 10)).foregroundStyle(UstaTheme.dim2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func eventRow(_ e: Usta_V1_Event) -> some View {
        let isFresh = bus.freshIds.contains(e.id)
        let subs = bus.subscribers(of: e.topic).filter { $0 != e.fromRole }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(UstaTheme.roleColor(for: e.fromRole)).frame(width: 7, height: 7)
                Text("@\(e.fromRole)").font(.system(size: 11, weight: .semibold))
                Text(e.topic).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(UstaTheme.cell)
                    .clipShape(Capsule())
                    .foregroundStyle(UstaTheme.dim)
                Spacer()
                if isFresh {
                    Text("NEW")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            Text(e.summary).font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if !e.filesChanged.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(e.filesChanged.prefix(6), id: \.self) { f in
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 8))
                                .foregroundStyle(.green)
                            Text(f)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.green)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if e.filesChanged.count > 6 {
                        Text("…+\(e.filesChanged.count - 6) more")
                            .font(.system(size: 9)).foregroundStyle(UstaTheme.dim)
                    }
                }
            }
            if !subs.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                    Text("auto-dispatched → ")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(subs.map { "@\($0)" }.joined(separator: ", "))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isFresh ? Color.orange.opacity(0.08) : UstaTheme.cell)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFresh ? Color.orange.opacity(0.6) : UstaTheme.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
