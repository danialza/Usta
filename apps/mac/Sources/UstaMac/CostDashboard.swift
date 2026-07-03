import SwiftUI
import UstaProto

/// Per-role cost dashboard — where the tokens actually went.
/// Data comes from the daemon's GetCosts (parsed from claude/codex local
/// session logs). Estimates, refreshed on open + manual refresh.
struct CostDashboard: View {
    let workspaceID: String
    @EnvironmentObject var client: UstaClientModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: Usta_V1_CostReport?
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(UstaTheme.accentTeal)
                Text("Team cost").font(.title3.weight(.semibold))
                if let r = report {
                    Text(String(format: "$%.2f total", r.totalUsd))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(UstaTheme.accentTeal.opacity(0.15))
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    Task { await load() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain)
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(UstaTheme.dim)
            }
            .padding(16)

            Divider().overlay(UstaTheme.border)

            if loading {
                ProgressView("Scanning session logs…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let r = report, !r.roles.isEmpty {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(r.roles.enumerated()), id: \.offset) { _, rc in
                            costRow(rc, maxCost: r.roles.map(\.costUsd).max() ?? 1)
                        }
                    }
                    .padding(16)
                }
                Divider().overlay(UstaTheme.border)
                Text("Estimated from local claude/codex session logs (\(sessionCount) sessions). Public API prices — subscription plans may differ.")
                    .font(.system(size: 10)).foregroundStyle(UstaTheme.dim2)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(UstaTheme.dim)
                    Text("No usage found yet").foregroundStyle(UstaTheme.dim)
                    Text("Costs appear after roles run their CLI sessions.")
                        .font(.system(size: 11)).foregroundStyle(UstaTheme.dim2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 520, height: 440)
        .background(UstaTheme.panel)
        .task { await load() }
    }

    private var sessionCount: Int {
        Int(report?.roles.reduce(0) { $0 + $1.sessions } ?? 0)
    }

    private func load() async {
        loading = true
        report = await client.getCosts(workspaceID: workspaceID)
        loading = false
    }

    private func costRow(_ rc: Usta_V1_RoleCost, maxCost: Double) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Circle().fill(UstaTheme.roleColor(for: rc.role)).frame(width: 8, height: 8)
                Text("@\(rc.role)").font(.system(size: 13, weight: .semibold))
                Text(rc.vendor)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(UstaTheme.cell).clipShape(Capsule())
                    .foregroundStyle(UstaTheme.dim)
                Spacer()
                Text(String(format: "$%.3f", rc.costUsd))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(UstaTheme.cell)
                    Capsule()
                        .fill(UstaTheme.roleColor(for: rc.role))
                        .frame(width: max(3, geo.size.width * (maxCost > 0 ? rc.costUsd / maxCost : 0)))
                }
            }
            .frame(height: 6)
            Text("\(fmt(rc.inputTokens)) in · \(fmt(rc.outputTokens)) out · \(fmt(rc.cacheReadTokens)) cached · \(rc.sessions) session\(rc.sessions == 1 ? "" : "s")")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(UstaTheme.dim)
        }
        .padding(10)
        .background(UstaTheme.cell.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: UstaTheme.radiusSmall))
    }

    private func fmt(_ n: Int64) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...:     return String(format: "%.1fk", Double(n) / 1e3)
        default:           return "\(n)"
        }
    }
}
