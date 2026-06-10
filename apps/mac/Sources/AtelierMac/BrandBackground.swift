import SwiftUI

/// Modern luxury background: smooth navy gradient + faint geometric grid
/// pattern at ~4% opacity. Pattern auto-scales with the window so it stays
/// "one big responsive" canvas instead of repeating tile lines.
struct BrandBackground: View {
    /// Pattern intensity, 0–1. Defaults to 0.04 (4% — barely visible, premium).
    var patternOpacity: Double = 0.04

    var body: some View {
        ZStack {
            // 1. Smooth base gradient (cheap)
            UstaTheme.smoothBackground

            // 2. Large geometric border pattern — single big responsive shape
            //    (not tiled). Drawn once per resize; drawingGroup rasterizes.
            GeometryReader { geo in
                Canvas { ctx, sz in
                    drawGridLines(ctx: ctx, size: sz, opacity: patternOpacity)
                    drawCornerOrbs(ctx: ctx, size: sz, opacity: patternOpacity * 1.5)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .drawingGroup()
            .allowsHitTesting(false)
        }
    }

    /// Very fine diagonal grid (45°) — luxury watchface texture.
    private func drawGridLines(ctx: GraphicsContext, size: CGSize, opacity: Double) {
        let step: CGFloat = 56                                // big spacing
        let stroke: CGFloat = 0.6
        var ctx = ctx
        ctx.opacity = opacity

        // Diagonal NW→SE
        var x: CGFloat = -size.height
        while x < size.width + size.height {
            var p = Path()
            p.move(to: .init(x: x,                 y: 0))
            p.addLine(to: .init(x: x + size.height, y: size.height))
            ctx.stroke(p, with: .color(.white), lineWidth: stroke)
            x += step
        }
        // Diagonal NE→SW (lighter)
        ctx.opacity = opacity * 0.55
        var y: CGFloat = -size.width
        while y < size.height + size.width {
            var p = Path()
            p.move(to: .init(x: size.width,        y: y))
            p.addLine(to: .init(x: 0,              y: y + size.width))
            ctx.stroke(p, with: .color(.white), lineWidth: stroke)
            y += step
        }
    }

    /// One giant outlined hexagon orb in the top-right + one in bottom-left.
    /// Provides the "luxury frame" feel without busying the center.
    private func drawCornerOrbs(ctx: GraphicsContext, size: CGSize, opacity: Double) {
        var ctx = ctx
        ctx.opacity = opacity

        let r = min(size.width, size.height) * 0.45
        // Top-right orb
        let tr = Path { p in
            p.addEllipse(in: CGRect(
                x: size.width - r * 0.6,
                y: -r * 0.4,
                width: r * 1.2,
                height: r * 1.2))
        }
        ctx.stroke(tr, with: .color(.white), lineWidth: 1.0)

        // Bottom-left orb
        let bl = Path { p in
            p.addEllipse(in: CGRect(
                x: -r * 0.6,
                y: size.height - r * 0.6,
                width: r * 1.2,
                height: r * 1.2))
        }
        ctx.stroke(bl, with: .color(.white), lineWidth: 1.0)

        // Inner concentric — thinner
        ctx.opacity = opacity * 0.5
        let tr2 = Path { p in
            p.addEllipse(in: CGRect(
                x: size.width - r * 0.4,
                y: -r * 0.2,
                width: r * 0.8,
                height: r * 0.8))
        }
        ctx.stroke(tr2, with: .color(.white), lineWidth: 0.8)
    }
}
