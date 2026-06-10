import SwiftUI

/// Atelier dark palette. Tracks the proposal mockup
/// (Atelier-Mockups.html in the repo root).
enum AtelierTheme {
    static let bg          = Color(red: 0.102, green: 0.102, blue: 0.122) // #1a1a1f
    static let panel       = Color(red: 0.082, green: 0.082, blue: 0.094) // #15151a
    static let cell        = Color(red: 0.059, green: 0.059, blue: 0.071) // #0f0f12
    static let border      = Color(red: 0.165, green: 0.165, blue: 0.188) // #2a2a30
    static let sidebar     = Color(red: 0.102, green: 0.102, blue: 0.122) // #1a1a1f
    static let dim         = Color(red: 0.533, green: 0.533, blue: 0.580) // #888
    static let dim2        = Color(red: 0.400, green: 0.400, blue: 0.420) // #666

    /// Role badge palette. Mirrors the mockup's role-badge classes.
    static func roleColor(for name: String) -> Color {
        switch name.lowercased() {
        case "frontend", "front":              return Color(red: 0.055, green: 0.647, blue: 0.914) // #0ea5e9
        case "backend", "back":                return Color(red: 0.086, green: 0.639, blue: 0.290) // #16a34a
        case "security", "sec":                return Color(red: 0.863, green: 0.149, blue: 0.149) // #dc2626
        case "ui-ux", "uiux", "design", "ux":  return Color(red: 0.925, green: 0.282, blue: 0.600) // #ec4899
        case "devops", "platform", "infra":    return Color(red: 0.024, green: 0.714, blue: 0.831) // #06b6d4
        case "payments", "billing", "pay":     return Color(red: 0.961, green: 0.620, blue: 0.043) // #f59e0b
        case "pm", "orchestrator", "lead":     return Color(red: 0.545, green: 0.361, blue: 0.965) // #8b5cf6
        case "data", "dba", "db":              return Color(red: 0.286, green: 0.420, blue: 0.918) // #4f6bea
        case "ml", "ai":                       return Color(red: 0.643, green: 0.333, blue: 0.969) // #a455f7
        case "qa", "test", "qaengineer":       return Color(red: 0.090, green: 0.518, blue: 0.620) // #176c9e
        default:
            // Stable hash → pastel
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
