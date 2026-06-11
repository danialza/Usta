import SwiftUI
import AppKit

/// Single pre-rendered backdrop: gradient + faint pattern composited into
/// ONE NSImage at app launch. No SwiftUI gradient compositing, no
/// blendMode, no per-paint resampling. Cheapest possible — just blit.
struct BrandBackground: View {
    var body: some View {
        Image(nsImage: Self.composed)
            .resizable(resizingMode: .stretch)
            .interpolation(.none)
            .allowsHitTesting(false)
    }

    /// 1024×1024 master. Gradient + diagonals + orbs flattened. Stretched
    /// by SwiftUI to fill window — lines look diagonal at any aspect.
    private static let composed: NSImage = {
        let side: CGFloat = 1024
        let img = NSImage(size: CGSize(width: side, height: side))
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        // Gradient base (top warmer → middle deep navy → bottom purple tint)
        let stops: [(CGFloat, NSColor)] = [
            (0.00, NSColor(srgbRed: 0.039, green: 0.043, blue: 0.094, alpha: 1)), // #0a0b18
            (0.55, NSColor(srgbRed: 0.020, green: 0.031, blue: 0.063, alpha: 1)), // #050810
            (1.00, NSColor(srgbRed: 0.027, green: 0.020, blue: 0.063, alpha: 1)), // #070510
        ]
        let colors = stops.map { $0.1.cgColor } as CFArray
        let locs   = stops.map { $0.0 }
        let space  = CGColorSpaceCreateDeviceRGB()
        if let grad = CGGradient(colorsSpace: space, colors: colors, locations: locs) {
            ctx.drawLinearGradient(
                grad,
                start: CGPoint(x: side * 0.5, y: side),
                end:   CGPoint(x: side * 0.5, y: 0),
                options: []
            )
        }

        // Faint diagonal grid (NW→SE) at ~4% white
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.04).cgColor)
        ctx.setLineWidth(0.7)
        let step: CGFloat = 56
        var x: CGFloat = -side
        while x < side * 2 {
            ctx.move(to: CGPoint(x: x,         y: 0))
            ctx.addLine(to: CGPoint(x: x + side, y: side))
            x += step
        }
        ctx.strokePath()

        // Counter-diagonal at half intensity
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.022).cgColor)
        var y: CGFloat = -side
        while y < side * 2 {
            ctx.move(to: CGPoint(x: side, y: y))
            ctx.addLine(to: CGPoint(x: 0,    y: y + side))
            y += step
        }
        ctx.strokePath()

        // Two corner orbs
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.055).cgColor)
        ctx.setLineWidth(1.2)
        ctx.strokeEllipse(in: CGRect(x: side * 0.7,  y: -side * 0.1,
                                    width: side * 0.8, height: side * 0.8))
        ctx.strokeEllipse(in: CGRect(x: -side * 0.1, y: side * 0.55,
                                    width: side * 0.8, height: side * 0.8))

        return img
    }()
}
