import Foundation
import SwiftUI

/// Lightweight update check against GitHub Releases — no Sparkle, no signing
/// infrastructure. On launch (max once per 24h) fetch the latest release tag,
/// compare against the bundle version, and surface a banner if newer.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Update: Equatable {
        let version: String
        let url: URL
    }

    @Published var available: Update?

    static let repo = "danialza/Usta"
    private static let lastCheckKey = "usta.update.lastCheck"
    private static let skipVersionKey = "usta.update.skipVersion"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkOnLaunch() async {
        // Throttle: at most one network hit per 24h.
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        if now - last < 86_400 { return }
        await check(force: false)
    }

    func check(force: Bool) async {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String,
              let page = URL(string: html)
        else { return }

        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        if !force, UserDefaults.standard.string(forKey: Self.skipVersionKey) == latest { return }
        if Self.isNewer(latest, than: currentVersion) {
            available = Update(version: latest, url: page)
        } else if force {
            available = nil
        }
    }

    func skip(_ version: String) {
        UserDefaults.standard.set(version, forKey: Self.skipVersionKey)
        available = nil
    }

    /// Numeric semver compare: "0.1.2" > "0.1.1". Non-numeric parts ignored.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let (pa, pb) = (parts(a), parts(b))
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Slim top banner shown when a newer release exists.
struct UpdateBanner: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let up = checker.available {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(UstaTheme.accentTeal)
                Text("Usta \(up.version) is out — you're on \(checker.currentVersion)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                Spacer()
                Button("Release notes") { NSWorkspace.shared.open(up.url) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Skip") { checker.skip(up.version) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(UstaTheme.dim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(UstaTheme.accentTeal.opacity(0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(UstaTheme.accentTeal.opacity(0.3)), alignment: .bottom)
        }
    }
}
