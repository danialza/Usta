import SwiftUI
import AppKit

/// Inline Usta mark — uses the official transparent-background PNG bundled
/// in Resources/usta-logo.png. No SwiftUI Canvas redraw, no SVG decode —
/// just NSImage load + Image render. Scales by `size`.
struct UstaLogo: View {
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let img = Self.cached {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
            } else {
                // Fallback: tinted SF symbol while bundle resource loads.
                Image(systemName: "rectangle.3.group.bubble")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: size, height: size)
    }

    /// Lazy-loaded once from the SPM bundle. Avoids per-frame disk I/O.
    private static let cached: NSImage? = {
        if let url = Bundle.module.url(forResource: "usta-logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }()
}
