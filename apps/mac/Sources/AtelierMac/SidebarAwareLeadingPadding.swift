import SwiftUI

/// Reads the host view's global x-origin and conditionally pads the
/// leading edge to clear macOS traffic lights + sidebar-toggle button
/// when the sidebar is collapsed. Cheap — GeometryReader only fires on
/// layout pass, not on every body call.
struct SidebarAwareLeadingPadding: ViewModifier {
    /// Traffic-light cluster reaches ~80px from window edge.
    private let clearance: CGFloat = 80
    /// Below this threshold we assume the sidebar is collapsed/hidden.
    private let collapsedThreshold: CGFloat = 40

    @State private var globalX: CGFloat = 9999

    func body(content: Content) -> some View {
        content
            .padding(.leading, globalX < collapsedThreshold ? clearance : 14)
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
