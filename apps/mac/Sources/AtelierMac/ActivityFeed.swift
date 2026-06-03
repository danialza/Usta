import SwiftUI
import AtelierProto

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
            Divider().overlay(AtelierTheme.border)
            nextBanner
            Divider().overlay(AtelierTheme.border)
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
        .background(AtelierTheme.panel)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
            Text("Team Activity").font(.headline)
            Spacer()
            Text("\(bus.events.count)").font(.caption2).foregroundStyle(AtelierTheme.dim)
        }
        .padding(10)
    }

    private var nextBanner: some View {
        let ready = bus.readyNow
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: ready.isEmpty ? "checkmark.circle" : "arrow.right.circle.fill")
                    .foregroundStyle(ready.isEmpty ? Color.green : Color.accentColor)
                Text(ready.isEmpty ? "All caught up" : "Next ready")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AtelierTheme.dim)
                Spacer()
            }
            if ready.isEmpty {
                Text("No role waiting on a fresh event")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(ready, id: \.self) { name in
                    readyRow(name)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(AtelierTheme.cell.opacity(0.4))
    }

    private func readyRow(_ name: String) -> some View {
        let conflicts = bus.conflicts(with: name)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(AtelierTheme.roleColor(for: name)).frame(width: 6, height: 6)
                Text("@\(name)").font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    NotificationCenter.default.post(name: .atelierKickoffRole, object: name)
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
            Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(AtelierTheme.dim2)
            Text("No handoffs yet.").font(.caption).foregroundStyle(AtelierTheme.dim)
            Text("When an assistant publishes an event, it appears here and downstream roles auto-react.")
                .font(.system(size: 10)).foregroundStyle(AtelierTheme.dim2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    private func eventRow(_ e: Atelier_V1_Event) -> some View {
        let isFresh = bus.freshIds.contains(e.id)
        let subs = bus.subscribers(of: e.topic).filter { $0 != e.fromRole }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(AtelierTheme.roleColor(for: e.fromRole)).frame(width: 7, height: 7)
                Text("@\(e.fromRole)").font(.system(size: 11, weight: .semibold))
                Text(e.topic).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(AtelierTheme.cell)
                    .clipShape(Capsule())
                    .foregroundStyle(AtelierTheme.dim)
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
                            .font(.system(size: 9)).foregroundStyle(AtelierTheme.dim)
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
        .background(isFresh ? Color.orange.opacity(0.08) : AtelierTheme.cell)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFresh ? Color.orange.opacity(0.6) : AtelierTheme.border)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
