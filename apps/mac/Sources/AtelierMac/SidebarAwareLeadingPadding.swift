import SwiftUI

/// Environment key set by ContentView when the NavigationSplitView's
/// columnVisibility is .detailOnly. Children read this to decide whether
/// to reserve space for the macOS traffic-lights cluster.
private struct SidebarCollapsedKey: EnvironmentKey {
    static let defaultValue: Bool = false
}
extension EnvironmentValues {
    var sidebarCollapsed: Bool {
        get { self[SidebarCollapsedKey.self] }
        set { self[SidebarCollapsedKey.self] = newValue }
    }
}

/// Responsive header inset.
///
/// Open sidebar  → 14px leading + 22px top (title hugs pane edge).
/// Closed sidebar → 96px leading + 22px top (clear traffic-lights cluster
///                  AND the sidebar-toggle button on the left).
struct SidebarAwareLeadingPadding: ViewModifier {
    @Environment(\.sidebarCollapsed) private var collapsed

    func body(content: Content) -> some View {
        content
            // Closed: 78px clears the floating toggle button (~70px wide
            // from the window edge) with minimal extra gap. Open: 14.
            .padding(.leading, collapsed ? 78 : 14)
            .padding(.top, 6)
    }
}
