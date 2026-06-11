import SwiftUI
import AppKit

/// ONE static NSImage holds gradient + tiled white-tinted Usta pattern.
/// View body is a single resizable Image — no Canvas, no per-render
/// drawing. Stretches with the window via SwiftUI Image resize. Cheap.
struct BrandBackground: View {
    var body: some View {
        Image(nsImage: Self.composed)
            .resizable(resizingMode: .stretch)
            .interpolation(.none)
            .allowsHitTesting(false)
    }

    /// 1600×1600 master. Bottom layer = navy gradient, top layer = tiled
    /// Usta mark inverted to white at 5% opacity, half-tile column offset.
    /// Built once on first access, retained for app lifetime.
    private static let composed: NSImage = {
        let side: CGFloat = 1600
        let img = NSImage(size: CGSize(width: side, height: side))
        img.lockFocus()
        defer { img.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

        // 1) Vertical gradient (warm top → deep navy → purple-tint bottom)
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

        // 2) Tiled Usta mark, white silhouette at 5%
        if let pattern = loadPattern() {
            ctx.saveGState()
            ctx.setAlpha(0.05)
            let tile: CGFloat = 220
            var col = 0
            var x: CGFloat = -tile
            while x < side + tile {
                let yOffset = (col % 2 == 0) ? CGFloat(0) : tile / 2
                var y: CGFloat = -tile + yOffset
                while y < side + tile {
                    pattern.draw(
                        in: CGRect(x: x, y: y, width: tile, height: tile),
                        from: .zero,
                        operation: .sourceOver,
                        fraction: 1.0
                    )
                    y += tile
                }
                x += tile
                col += 1
            }
            ctx.restoreGState()
        }

        return img
    }()

    /// Loads usta-pattern.png and converts every pixel to white while
    /// preserving alpha — so the mark shows on a dark navy bg.
    private static func loadPattern() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "usta-pattern", withExtension: "png"),
              let src = NSImage(contentsOf: url) else { return nil }
        let size = src.size
        let out = NSImage(size: size)
        out.lockFocus()
        defer { out.unlockFocus() }
        // Draw original to use its alpha as a mask
        src.draw(in: NSRect(origin: .zero, size: size),
                 from: .zero,
                 operation: .sourceOver,
                 fraction: 1.0)
        // Recolor: take the alpha shape, fill with white using sourceIn
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.setBlendMode(.sourceIn)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        return out
    }
}
