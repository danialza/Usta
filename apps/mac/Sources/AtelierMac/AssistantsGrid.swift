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

    var body: some View {
        let shown = focus == nil ? roles : roles.filter { $0.name == focus }
        Group {
            if shown.isEmpty {
                empty
            } else if shown.count == 1 {
                AssistantPane(workspaceID: workspaceID, role: shown[0])
            } else {
                grid(shown)
            }
        }
    }

    private func cols(for width: CGFloat, count: Int) -> Int {
        let target: Int
        if width < 700 { target = 1 }
        else if width < 1200 { target = 2 }
        else if width < 1700 { target = 3 }
        else { target = 4 }
        return max(1, min(target, count))
    }

    private func grid(_ shown: [Atelier_V1_Role]) -> some View {
        GeometryReader { geo in
            let n = cols(for: geo.size.width, count: shown.count)
            let layout = Array(repeating: GridItem(.flexible(), spacing: 8), count: n)
            ScrollView {
                LazyVGrid(columns: layout, spacing: 8) {
                    ForEach(shown, id: \.name) { role in
                        AssistantPane(
                            workspaceID: workspaceID,
                            role: role,
                            collapsed: collapsed.contains(role.name),
                            onToggleCollapse: { toggle(role.name) }
                        )
                        .frame(minHeight: collapsed.contains(role.name) ? 56 : 340)
                        .background(AtelierTheme.cell)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(AtelierTheme.roleColor(for: role.name).opacity(0.35))
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
