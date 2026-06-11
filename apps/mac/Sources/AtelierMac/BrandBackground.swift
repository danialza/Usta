import SwiftUI

/// Plain smooth navy gradient. No pattern, no overlay — cheapest possible
/// (SwiftUI LinearGradient is hardware-accelerated and free).
struct BrandBackground: View {
    var body: some View {
        UstaTheme.smoothBackground
    }
}
