import SwiftUI

/// Atelier dark palette. Static sRGB — no dynamic color lookups, no
/// material compositing. Fast.
enum AtelierTheme {
    static let bg          = Color(red: 0.102, green: 0.102, blue: 0.122) // #1a1a1f
    static let panel       = Color(red: 0.082, green: 0.082, blue: 0.094) // #15151a
    static let cell        = Color(red: 0.059, green: 0.059, blue: 0.071) // #0f0f12
    static let border      = Color(red: 0.165, green: 0.165, blue: 0.188) // #2a2a30
    static let sidebar     = Color(red: 0.102, green: 0.102, blue: 0.122) // #1a1a1f
    static let dim         = Color(red: 0.533, green: 0.533, blue: 0.580) // #888
    static let dim2        = Color(red: 0.400, green: 0.400, blue: 0.420) // #666

    // Standard radii.
    static let radiusSmall:  CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge:  CGFloat = 14

    static func roleColor(for name: String) -> Color {
        switch name.lowercased() {
        case "frontend", "front":              return Color(red: 0.055, green: 0.647, blue: 0.914)
        case "backend", "back":                return Color(red: 0.086, green: 0.639, blue: 0.290)
        case "security", "sec":                return Color(red: 0.863, green: 0.149, blue: 0.149)
        case "ui-ux", "uiux", "design", "ux":  return Color(red: 0.925, green: 0.282, blue: 0.600)
        case "devops", "platform", "infra":    return Color(red: 0.024, green: 0.714, blue: 0.831)
        case "payments", "billing", "pay":     return Color(red: 0.961, green: 0.620, blue: 0.043)
        case "pm", "orchestrator", "lead":     return Color(red: 0.545, green: 0.361, blue: 0.965)
        case "data", "dba", "db":              return Color(red: 0.286, green: 0.420, blue: 0.918)
        case "ml", "ai":                       return Color(red: 0.643, green: 0.333, blue: 0.969)
        case "qa", "test", "qaengineer":       return Color(red: 0.090, green: 0.518, blue: 0.620)
        default:
            var h: UInt32 = 5381
            for b in name.utf8 { h = (h << 5).addingReportingOverflow(h).0.addingReportingOverflow(UInt32(b)).0 }
            let hue = Double(h % 360) / 360.0
            return Color(hue: hue, saturation: 0.55, brightness: 0.78)
        }
    }

    static func roleEmoji(for name: String, fallback: String) -> String {
        switch name.lowercased() {
        case "frontend":      return "🎨"
        case "backend":       return "⚙️"
        case "security":      return "🔒"
        case "ui-ux", "design": return "🎭"
        case "devops":        return "🚀"
        case "payments":      return "💳"
        case "pm":            return "🧠"
        case "data", "dba":   return "🗄️"
        case "ml", "ai":      return "🤖"
        case "qa", "test":    return "🧪"
        default:              return fallback.isEmpty ? "•" : fallback
        }
    }
}

// MARK: - Stubs so call sites stay compiling

/// Kept as no-op shell so existing call sites don't break. Always dark.
@MainActor
final class AppearanceManager: ObservableObject {
    static let shared = AppearanceManager()
}

/// Empty placeholder — header used to render the toggle pill here.
struct AppearanceToggle: View {
    var manager: AppearanceManager
    var body: some View { EmptyView() }
}
