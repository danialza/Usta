import SwiftUI

/// Inline SwiftUI rendering of the Usta mark. Six vertical agent panes
/// (cyan / blue / pink, each split into two columns) sitting on a U base.
/// Cheap to render — uses Canvas + drawingGroup for GPU rasterization.
struct UstaLogo: View {
    var size: CGFloat = 24
    var monochrome: Bool = false
    var tint: Color = .white

    var body: some View {
        Canvas { ctx, _ in
            let s = size / 256.0
            func sc(_ x: CGFloat) -> CGFloat { x * s }

            // Six pane rects (left two cyan, mid two blue, right two pink)
            let leftA = Path { p in
                p.move(to: .init(x: sc(38),  y: sc(30)))
                p.addLine(to: .init(x: sc(70),  y: sc(30)))
                p.addLine(to: .init(x: sc(70),  y: sc(160)))
                p.addLine(to: .init(x: sc(38),  y: sc(168)))
                p.closeSubpath()
            }
            let leftB = Path { p in
                p.move(to: .init(x: sc(78),  y: sc(32)))
                p.addLine(to: .init(x: sc(102), y: sc(32)))
                p.addLine(to: .init(x: sc(102), y: sc(158)))
                p.addLine(to: .init(x: sc(78),  y: sc(168)))
                p.closeSubpath()
            }
            let midA = Path { p in
                p.move(to: .init(x: sc(110), y: sc(30)))
                p.addLine(to: .init(x: sc(134), y: sc(30)))
                p.addLine(to: .init(x: sc(134), y: sc(160)))
                p.addLine(to: .init(x: sc(110), y: sc(160)))
                p.closeSubpath()
            }
            let midB = Path { p in
                p.move(to: .init(x: sc(142), y: sc(30)))
                p.addLine(to: .init(x: sc(166), y: sc(30)))
                p.addLine(to: .init(x: sc(166), y: sc(160)))
                p.addLine(to: .init(x: sc(142), y: sc(160)))
                p.closeSubpath()
            }
            let rightA = Path { p in
                p.move(to: .init(x: sc(174), y: sc(32)))
                p.addLine(to: .init(x: sc(198), y: sc(32)))
                p.addLine(to: .init(x: sc(198), y: sc(158)))
                p.addLine(to: .init(x: sc(174), y: sc(168)))
                p.closeSubpath()
            }
            let rightB = Path { p in
                p.move(to: .init(x: sc(206), y: sc(30)))
                p.addLine(to: .init(x: sc(238), y: sc(30)))
                p.addLine(to: .init(x: sc(238), y: sc(168)))
                p.addLine(to: .init(x: sc(206), y: sc(160)))
                p.closeSubpath()
            }

            // U-base left + right
            let baseL = Path { p in
                p.move(to: .init(x: sc(38),  y: sc(168)))
                p.addLine(to: .init(x: sc(128), y: sc(215)))
                p.addLine(to: .init(x: sc(128), y: sc(235)))
                p.addLine(to: .init(x: sc(38),  y: sc(195)))
                p.closeSubpath()
            }
            let baseR = Path { p in
                p.move(to: .init(x: sc(128), y: sc(215)))
                p.addLine(to: .init(x: sc(238), y: sc(168)))
                p.addLine(to: .init(x: sc(238), y: sc(195)))
                p.addLine(to: .init(x: sc(128), y: sc(235)))
                p.closeSubpath()
            }
            let fold = Path { p in
                p.move(to: .init(x: sc(122), y: sc(215)))
                p.addLine(to: .init(x: sc(134), y: sc(215)))
                p.addLine(to: .init(x: sc(128), y: sc(240)))
                p.closeSubpath()
            }

            if monochrome {
                let t = tint
                ctx.fill(leftA,  with: .color(t))
                ctx.fill(leftB,  with: .color(t.opacity(0.92)))
                ctx.fill(midA,   with: .color(t))
                ctx.fill(midB,   with: .color(t))
                ctx.fill(rightA, with: .color(t.opacity(0.92)))
                ctx.fill(rightB, with: .color(t))
                ctx.fill(baseL,  with: .color(t.opacity(0.85)))
                ctx.fill(baseR,  with: .color(t.opacity(0.85)))
                return
            }

            // Brand gradients — vertical for panes, diagonal for base
            let cyan = Gradient(colors: [Color(hex: 0x3DECFF), Color(hex: 0x15D5F0), Color(hex: 0x0BB1CC)])
            let blue = Gradient(colors: [Color(hex: 0x5A9DFF), Color(hex: 0x5A7BF0), Color(hex: 0x4B5FD8)])
            let pink = Gradient(colors: [Color(hex: 0xFF6BC4), Color(hex: 0xF45BA5), Color(hex: 0xE14C8E)])
            let baseLG = Gradient(colors: [Color(hex: 0x4B5FD8), Color(hex: 0x7C5FF0)])
            let baseRG = Gradient(colors: [Color(hex: 0x9760EE), Color(hex: 0x6A4DD8)])

            func verticalShading(_ g: Gradient) -> GraphicsContext.Shading {
                .linearGradient(g, startPoint: .init(x: 0, y: 0), endPoint: .init(x: 0, y: size))
            }
            func diagonalShading(_ g: Gradient) -> GraphicsContext.Shading {
                .linearGradient(g, startPoint: .init(x: 0, y: 0), endPoint: .init(x: size, y: size * 0.5))
            }

            ctx.fill(leftA,  with: verticalShading(cyan))
            ctx.fill(leftB,  with: verticalShading(cyan))
            ctx.fill(midA,   with: verticalShading(blue))
            ctx.fill(midB,   with: verticalShading(blue))
            ctx.fill(rightA, with: verticalShading(pink))
            ctx.fill(rightB, with: verticalShading(pink))
            ctx.fill(baseL,  with: diagonalShading(baseLG))
            ctx.fill(baseR,  with: diagonalShading(baseRG))
            ctx.fill(fold,   with: .color(Color(hex: 0x1A0F40).opacity(0.55)))
        }
        .frame(width: size, height: size)
        .drawingGroup()
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
