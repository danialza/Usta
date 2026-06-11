import SwiftUI

/// Floating toast stack pinned to top-right of the workspace area.
/// Driven by WorkspaceBus.toasts; each toast auto-dismisses after ~5s.
struct ToastStack: View {
    @EnvironmentObject var bus: WorkspaceBus

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(bus.toasts) { t in
                toastView(t)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, 12)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .topTrailing)
        .animation(.easeInOut(duration: 0.2), value: bus.toasts)
        .allowsHitTesting(false)   // visual only; clicking passes through
    }

    private func toastView(_ t: WorkspaceBus.ToastItem) -> some View {
        let color: Color = {
            switch t.kind {
            case .regen: return .orange
            case .ready: return .blue
            case .info:  return .gray
            }
        }()
        let icon: String = {
            switch t.kind {
            case .regen: return "arrow.clockwise.circle.fill"
            case .ready: return "arrow.right.circle.fill"
            case .info:  return "info.circle.fill"
            }
        }()
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title).font(.system(size: 11, weight: .semibold))
                Text(t.body).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 280, alignment: .leading)
        }
        .padding(10)
        .background(.thickMaterial)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.55)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}
