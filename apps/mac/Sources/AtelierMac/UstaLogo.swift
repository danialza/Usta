import SwiftUI

/// Inline SVG-equivalent Usta mark. Draws the three vertical agent panes
/// joined by a U base, using the brand gradient. Scales by `size`.
struct UstaLogo: View {
    var size: CGFloat = 24
    var monochrome: Bool = false
    var tint: Color = .white

    var body: some View {
        Canvas { ctx, _ in
            let s = size / 256.0   // SVG viewBox is 256

            func scale(_ x: CGFloat) -> CGFloat { x * s }

            // Pane TEAL — leans right (top-left)
            let teal = Path { p in
                p.move(to:    .init(x: scale(38),  y: scale(36)))
                p.addLine(to: .init(x: scale(70),  y: scale(28)))
                p.addLine(to: .init(x: scale(90),  y: scale(56)))
                p.addLine(to: .init(x: scale(90),  y: scale(156)))
                p.addLine(to: .init(x: scale(58),  y: scale(168)))
                p.addLine(to: .init(x: scale(58),  y: scale(76)))
                p.closeSubpath()
            }
            // Pane PURPLE — tallest, center
            let purple = Path { p in
                p.move(to:    .init(x: scale(105), y: scale(26)))
                p.addLine(to: .init(x: scale(137), y: scale(18)))
                p.addLine(to: .init(x: scale(157), y: scale(46)))
                p.addLine(to: .init(x: scale(157), y: scale(188)))
                p.addLine(to: .init(x: scale(125), y: scale(200)))
                p.addLine(to: .init(x: scale(125), y: scale(66)))
                p.closeSubpath()
            }
            // Pane PINK — right
            let pink = Path { p in
                p.move(to:    .init(x: scale(172), y: scale(36)))
                p.addLine(to: .init(x: scale(204), y: scale(28)))
                p.addLine(to: .init(x: scale(224), y: scale(56)))
                p.addLine(to: .init(x: scale(224), y: scale(156)))
                p.addLine(to: .init(x: scale(192), y: scale(168)))
                p.addLine(to: .init(x: scale(192), y: scale(76)))
                p.closeSubpath()
            }
            // U base
            let baseU = Path { p in
                p.move(to:    .init(x: scale(58),  y: scale(156)))
                p.addLine(to: .init(x: scale(90),  y: scale(156)))
                p.addLine(to: .init(x: scale(90),  y: scale(200)))
                p.addLine(to: .init(x: scale(172), y: scale(200)))
                p.addLine(to: .init(x: scale(172), y: scale(156)))
                p.addLine(to: .init(x: scale(204), y: scale(156)))
                p.addLine(to: .init(x: scale(204), y: scale(200)))
                p.addLine(to: .init(x: scale(192), y: scale(220)))
                p.addLine(to: .init(x: scale(70),  y: scale(220)))
                p.addLine(to: .init(x: scale(58),  y: scale(200)))
                p.closeSubpath()
            }

            if monochrome {
                ctx.fill(teal,   with: .color(tint))
                ctx.fill(purple, with: .color(tint))
                ctx.fill(pink,   with: .color(tint))
                ctx.fill(baseU,  with: .color(tint))
            } else {
                ctx.fill(teal,   with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x34E8B8), Color(hex: 0x2DD4A7), Color(hex: 0x1FB389)]),
                    startPoint: .zero, endPoint: .init(x: size * 0.4, y: size)))
                ctx.fill(purple, with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x8B7CF6), Color(hex: 0x7C6CF0), Color(hex: 0x6347D9)]),
                    startPoint: .zero, endPoint: .init(x: size * 0.6, y: size)))
                ctx.fill(pink,   with: .linearGradient(
                    Gradient(colors: [Color(hex: 0xF472B6), Color(hex: 0xEC4899), Color(hex: 0xD62D80)]),
                    startPoint: .zero, endPoint: .init(x: size * 0.4, y: size)))
                ctx.fill(baseU, with: .linearGradient(
                    Gradient(colors: [Color(hex: 0x2DD4A7), Color(hex: 0x7C6CF0), Color(hex: 0xEC4899)]),
                    startPoint: .zero, endPoint: .init(x: size, y: 0)))
            }
        }
        .frame(width: size, height: size)
        .drawingGroup()                              // rasterize → cheap to compose
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >>  8) & 0xFF) / 255.0,
            blue:  Double((hex >>  0) & 0xFF) / 255.0
        )
    }
}
