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
            // Always small leading — content sits flush-left.
            .padding(.leading, 14)
            // When closed, push content DOWN past the floating
            // traffic-light + toggle-button row instead of sideways.
            .padding(.top, collapsed ? 40 : 6)
    }
}
