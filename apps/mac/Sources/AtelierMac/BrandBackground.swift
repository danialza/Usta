import SwiftUI
import AppKit

/// Modern luxury background: smooth navy gradient + faint geometric grid
/// pattern at ~4% opacity. Pattern is rasterized ONCE to NSImage and
/// reused via an Image view, so window-focus changes / app switches
/// don't re-execute Canvas drawing.
struct BrandBackground: View {
    var body: some View {
        ZStack {
            UstaTheme.smoothBackground
            Image(nsImage: Self.patternImage)
                .resizable()
                .interpolation(.high)
                .blendMode(.screen)
                .opacity(0.06)
                .allowsHitTesting(false)
        }
    }

    /// 2048×2048 master pattern. Drawn once, retained for app lifetime.
    private static let patternImage: NSImage = {
        let side: CGFloat = 2048
        let img = NSImage(size: CGSize(width: side, height: side))
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(0.8)

        // 45° diagonal lines NW→SE
        let step: CGFloat = 64
        var x: CGFloat = -side
        while x < side * 2 {
            ctx.move(to: CGPoint(x: x,         y: 0))
            ctx.addLine(to: CGPoint(x: x + side, y: side))
            x += step
        }
        ctx.strokePath()

        // Counter-diagonal at half intensity
        ctx.setAlpha(0.55)
        var y: CGFloat = -side
        while y < side * 2 {
            ctx.move(to: CGPoint(x: side, y: y))
            ctx.addLine(to: CGPoint(x: 0,    y: y + side))
            y += step
        }
        ctx.strokePath()

        // Two large outline orbs
        ctx.setAlpha(0.4)
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: CGRect(x: side * 0.7,  y: -side * 0.1, width: side * 0.8, height: side * 0.8))
        ctx.strokeEllipse(in: CGRect(x: -side * 0.1, y: side * 0.5,  width: side * 0.8, height: side * 0.8))

        return img
    }()
}
