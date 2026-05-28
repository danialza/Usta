import SwiftUI
import AtelierProto

/// Shared inter-agent activity feed. Polls ListEvents for the workspace.
struct ActivityFeed: View {
    let workspaceID: String
    @EnvironmentObject var client: AtelierClientModel
    @State private var events: [Atelier_V1_Event] = []
    @State private var pollTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.tint)
                Text("Team Activity").font(.headline)
                Spacer()
                Text("\(events.count)").font(.caption2).foregroundStyle(AtelierTheme.dim)
            }
            .padding(10)
            Divider().overlay(AtelierTheme.border)

            if events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(AtelierTheme.dim2)
                    Text("No handoffs yet.").font(.caption).foregroundStyle(AtelierTheme.dim)
                    Text("When an assistant finishes work it publishes here; subscribers pick it up.")
                        .font(.system(size: 10)).foregroundStyle(AtelierTheme.dim2)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(events, id: \.id) { e in
                            eventRow(e)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(AtelierTheme.panel)
        .task(id: workspaceID) {
            await refresh()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
    }

    private func eventRow(_ e: Atelier_V1_Event) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(AtelierTheme.roleColor(for: e.fromRole)).frame(width: 7, height: 7)
                Text("@\(e.fromRole)").font(.system(size: 11, weight: .semibold))
                Text(e.topic).font(.system(size: 10))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(AtelierTheme.cell)
                    .clipShape(Capsule())
                    .foregroundStyle(AtelierTheme.dim)
                Spacer()
            }
            Text(e.summary).font(.system(size: 12)).foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AtelierTheme.cell)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(AtelierTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func refresh() async {
        events = await client.listEvents(workspaceID: workspaceID, limit: 100)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }
}
