import SwiftUI

/// Reads the host view's global x-origin and conditionally pads BOTH
/// leading and top edges to clear macOS traffic lights + sidebar-toggle
/// button when the sidebar is collapsed.
///
/// Open sidebar  → minimal margins (14px / 4px), workspace title hugs
///                 the left edge of its pane.
/// Closed sidebar → 96px leading + 28px top so the title row clears
///                 the traffic light cluster AND the toggle button.
struct SidebarAwareLeadingPadding: ViewModifier {
    private let openLeading:   CGFloat = 14
    private let openTop:       CGFloat = 4
    private let closedLeading: CGFloat = 96
    private let closedTop:     CGFloat = 28
    /// Below this threshold we assume the sidebar is collapsed/hidden.
    private let collapsedThreshold: CGFloat = 40

    @State private var globalX: CGFloat = 9999

    func body(content: Content) -> some View {
        let collapsed = globalX < collapsedThreshold
        content
            .padding(.leading, collapsed ? closedLeading : openLeading)
            .padding(.top,     collapsed ? closedTop     : openTop)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(key: GlobalXKey.self,
                                    value: geo.frame(in: .global).minX)
                }
            )
            .onPreferenceChange(GlobalXKey.self) { newX in
                if abs(newX - globalX) > 1 { globalX = newX }
            }
    }
}

private struct GlobalXKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
