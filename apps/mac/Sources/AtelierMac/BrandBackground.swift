import SwiftUI
import AppKit

/// Smooth navy gradient base + tiled Usta-mark pattern overlay at very
/// low opacity. The mark PNG (brand/usta-pattern.png) is the user's
/// official black silhouette art. Tile honors window size automatically.
struct BrandBackground: View {
    var body: some View {
        ZStack {
            // 1. Pre-baked smooth gradient (cheap)
            UstaTheme.smoothBackground

            // 2. Pattern tile — uploaded Usta mark as wallpaper
            if let pattern = Self.patternImage {
                GeometryReader { geo in
                    let tile: CGFloat = 220
                    Canvas { ctx, sz in
                        var ctx = ctx
                        ctx.opacity = 0.05      // ~5% — luxurious whisper
                        var x: CGFloat = 0
                        while x < sz.width {
                            var y: CGFloat = 0
                            // Offset every other column so it doesn't grid up
                            let yOffset = (Int(x / tile) % 2 == 0) ? 0 : tile / 2
                            y += yOffset
                            while y < sz.height {
                                ctx.draw(Image(nsImage: pattern),
                                         in: CGRect(x: x, y: y, width: tile, height: tile))
                                y += tile
                            }
                            x += tile
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                .drawingGroup()
                .allowsHitTesting(false)
            }
        }
    }

    /// Loaded once from the bundle (Resources/usta-pattern.png).
    private static let patternImage: NSImage? = {
        if let url = Bundle.module.url(forResource: "usta-pattern", withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }()
}
