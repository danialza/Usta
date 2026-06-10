import SwiftUI
import AppKit

// MARK: - Appearance manager (system / dark / light)

enum AppearanceMode: String, CaseIterable, Identifiable {
    case dark, light
    var id: String { rawValue }
    var label: String {
        switch self {
        case .dark:  return "Dark"
        case .light: return "Light"
        }
    }
    var icon: String {
        switch self {
        case .dark:  return "moon.fill"
        case .light: return "sun.max.fill"
        }
    }
}

@MainActor
final class AppearanceManager: ObservableObject {
    @AppStorage("atelierAppearance") var mode: AppearanceMode = .dark {
        didSet { objectWillChange.send() }
    }
    var preferred: ColorScheme {
        switch mode {
        case .dark:  return .dark
        case .light: return .light
        }
    }
    static let shared = AppearanceManager()
}

// AppStorage doesn't natively know about our enum; route via raw String.
@propertyWrapper
struct AppStorageMode: DynamicProperty {
    @AppStorage("atelierAppearance") private var raw: String = AppearanceMode.dark.rawValue
    var wrappedValue: AppearanceMode {
        get { AppearanceMode(rawValue: raw) ?? .dark }
        nonmutating set { raw = newValue.rawValue }
    }
    var projectedValue: Binding<AppearanceMode> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

// MARK: - Dynamic colors (NSColor name+provider so light/dark resolve live)

private func dyn(_ name: String, light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark]) != nil
        return isDark ? dark : light
    })
}

private func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

/// Atelier palette — 2026 minimal. Soft warm-neutral grays, deep slate dark,
/// off-white light. Pairs auto-switch with the system or user override.
enum AtelierTheme {
    // Surface stack: bg < panel < cell. Border > separators above cells.
    static let bg      = dyn("bg",      light: rgb(248, 249, 251), dark: rgb(13, 14, 18))
    static let panel   = dyn("panel",   light: rgb(255, 255, 255), dark: rgb(20, 22, 28))
    static let cell    = dyn("cell",    light: rgb(243, 245, 248), dark: rgb(26, 29, 36))
    static let border  = dyn("border",  light: rgb(228, 231, 237), dark: rgb(42, 46, 56))
    static let sidebar = dyn("sidebar", light: rgb(250, 251, 253), dark: rgb(16, 17, 22))
    // Text dimming tiers.
    static let dim     = dyn("dim",     light: rgb(107, 114, 128), dark: rgb(141, 146, 160))
    static let dim2    = dyn("dim2",    light: rgb(156, 163, 175), dark: rgb(100, 105, 118))

    // Standard radii (use these everywhere instead of magic numbers).
    static let radiusSmall:  CGFloat = 6
    static let radiusMedium: CGFloat = 10
    static let radiusLarge:  CGFloat = 14

    /// Role badge palette. Same hues across themes; SwiftUI handles
    /// contrast against panel/cell since these are saturated accents.
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

// MARK: - Theme toggle pill (header)

/// 3-segment pill: System · Dark · Light. Lives in the workspace header.
struct AppearanceToggle: View {
    @ObservedObject var manager: AppearanceManager
    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppearanceMode.allCases) { m in
                Button {
                    manager.mode = m
                } label: {
                    Image(systemName: m.icon)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 22)
                        .foregroundStyle(manager.mode == m ? Color.primary : AtelierTheme.dim)
                        .background(
                            manager.mode == m
                                ? AtelierTheme.cell
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(m.label)
            }
        }
        .padding(2)
        .background(AtelierTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AtelierTheme.border))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
