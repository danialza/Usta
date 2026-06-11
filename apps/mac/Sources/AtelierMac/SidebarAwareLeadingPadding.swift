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
            // Just enough to clear the floating sidebar-toggle button
            // (~95px from window edge). Anything more leaves an awkward
            // gap. Open: 14 since sidebar takes the leading.
            .padding(.leading, collapsed ? 100 : 14)
            .padding(.top, 14)
    }
}
