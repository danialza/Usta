import SwiftUI

/// Usta brand palette. Deep navy canvas, signature teal → purple → pink
/// gradient. Pulled from brand/logo-mark.svg.
enum UstaTheme {
    // Surface stack — bg < panel < cell. Deep navy, warm undertone.
    static let bg          = Color(red: 0.020, green: 0.031, blue: 0.063) // #050810
    static let panel       = Color(red: 0.039, green: 0.055, blue: 0.094) // #0a0e18
    static let cell        = Color(red: 0.055, green: 0.075, blue: 0.125) // #0e1320
    static let sidebar     = Color(red: 0.027, green: 0.039, blue: 0.078) // #070a14
    static let border      = Color(red: 0.122, green: 0.149, blue: 0.196) // #1f2632
    static let dim         = Color(red: 0.545, green: 0.553, blue: 0.620) // #8b8d9e
    static let dim2        = Color(red: 0.380, green: 0.388, blue: 0.455) // #616374

    // Brand accents — match the logo gradient.
    static let accentTeal   = Color(red: 0.176, green: 0.831, blue: 0.655) // #2DD4A7
    static let accentPurple = Color(red: 0.486, green: 0.424, blue: 0.941) // #7C6CF0
    static let accentPink   = Color(red: 0.925, green: 0.282, blue: 0.600) // #EC4899
    static let accentAmber  = Color(red: 0.984, green: 0.749, blue: 0.141) // #FBBF24

    // Standard radii.
    static let radiusSmall:  CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge:  CGFloat = 14

    /// Role badge palette. Mapped to the brand gradient family so every
    /// role-tinted chip reads as part of the Usta system.
    static func roleColor(for name: String) -> Color {
        switch name.lowercased() {
        case "frontend", "front":              return accentTeal              // #2DD4A7
        case "backend", "back":                return Color(red: 0.118, green: 0.616, blue: 0.337) // #1F9D56
        case "security", "sec":                return Color(red: 0.886, green: 0.275, blue: 0.275) // #E24646
        case "ui-ux", "uiux", "design", "ux":  return accentPink              // #EC4899
        case "devops", "platform", "infra":    return Color(red: 0.094, green: 0.722, blue: 0.831) // #18B8D4
        case "payments", "billing", "pay":     return accentAmber             // #FBBF24
        case "pm", "orchestrator", "lead":     return accentPurple            // #7C6CF0
        case "data", "dba", "db":              return Color(red: 0.341, green: 0.439, blue: 0.965) // #5770F6
        case "ml", "ai":                       return Color(red: 0.643, green: 0.420, blue: 0.969) // #A46BF7
        case "qa", "test", "qaengineer":       return Color(red: 0.176, green: 0.604, blue: 0.722) // #2D9AB8
        case "docs", "documentation":          return Color(red: 0.612, green: 0.620, blue: 0.690) // #9C9EB0
        default:
            var h: UInt32 = 5381
            for b in name.utf8 { h = (h << 5).addingReportingOverflow(h).0.addingReportingOverflow(UInt32(b)).0 }
            let hue = Double(h % 360) / 360.0
            return Color(hue: hue, saturation: 0.55, brightness: 0.78)
        }
    }

    static func roleEmoji(for name: String, fallback: String) -> String {
        switch name.lowercased() {
        case "frontend":         return "🎨"
        case "backend":          return "⚙️"
        case "security":         return "🔒"
        case "ui-ux", "design":  return "🎭"
        case "devops":           return "🚀"
        case "payments":         return "💳"
        case "pm":               return "🧠"
        case "data", "dba":      return "🗄️"
        case "ml", "ai":         return "🤖"
        case "qa", "test":       return "🧪"
        case "docs":             return "📚"
        default:                 return fallback.isEmpty ? "•" : fallback
        }
    }

    /// Brand gradient — teal → purple → pink. Use sparingly: hero banners,
    /// CTAs, the unblock pill. Not for backgrounds (expensive to render).
    static let brandGradient = LinearGradient(
        colors: [accentTeal, accentPurple, accentPink],
        startPoint: .leading,
        endPoint: .trailing
    )
}
