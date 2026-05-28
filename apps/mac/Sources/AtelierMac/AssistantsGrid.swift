import SwiftUI
import AtelierProto

/// Grid of Claude-Code-style assistant panes — one per workspace role.
/// Each pane is a full ChatPane (transcript + composer + model picker).
struct AssistantsGrid: View {
    let workspaceID: String
    let roles: [Atelier_V1_Role]
    /// When non-nil, only this role is shown (focused/expanded).
    let focus: String?

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

    private func grid(_ shown: [Atelier_V1_Role]) -> some View {
        let cols = shown.count <= 2 ? shown.count : (shown.count <= 4 ? 2 : 3)
        let layout = Array(repeating: GridItem(.flexible(), spacing: 8), count: max(1, cols))
        return ScrollView {
            LazyVGrid(columns: layout, spacing: 8) {
                ForEach(shown, id: \.name) { role in
                    AssistantPane(workspaceID: workspaceID, role: role)
                        .frame(minHeight: 320)
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
