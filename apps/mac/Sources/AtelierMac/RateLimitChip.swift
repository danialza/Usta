import SwiftUI

/// Polls the daemon every ~3s for Anthropic rate-limit headers and shows a
/// compact chip in the workspace header: `API n/N · resets Xs`. Color codes
/// by headroom; emits a one-shot toast when remaining hits the gate.
@MainActor
final class RateLimitModel: ObservableObject {
    @Published var limit: Int64 = 0
    @Published var remaining: Int64 = 0
    @Published var resetMs: Int64 = 0
    @Published var lastUpdatedMs: Int64 = 0
    @Published var lastNotified: Int64 = 0   // unix ms of last toast

    private var pollTask: Task<Void, Never>? = nil

    func start(client: UstaClientModel, onCap: @escaping (String) -> Void) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let snap = await client.getRateLimit() {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.limit = snap.limit
                        self.remaining = snap.remaining
                        self.resetMs = snap.resetMs
                        self.lastUpdatedMs = snap.lastUpdatedMs
                        // Notify when remaining drops ≤ 2 (gate threshold), no more
                        // than once per 30s.
                        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                        if self.remaining <= 2 && (nowMs - self.lastNotified) > 30_000 {
                            self.lastNotified = nowMs
                            let waitS = max(0, (self.resetMs - nowMs) / 1000)
                            onCap("API \(self.remaining)/\(self.limit) — waiting \(waitS)s for Anthropic reset")
                        }
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    /// Seconds until reset_at, 0 if reset is in the past.
    var resetSeconds: Int {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return Int(max(0, resetMs - nowMs) / 1000)
    }

    var headroomFraction: Double {
        guard limit > 0 else { return 1.0 }
        return Double(remaining) / Double(limit)
    }
}

struct RateLimitChip: View {
    @ObservedObject var model: RateLimitModel

    var body: some View {
        if model.limit == 0 {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text("API")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(model.remaining)/\(model.limit)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
                if model.remaining <= 5 {
                    Text("· resets \(model.resetSeconds)s")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.10))
            .overlay(Capsule().stroke(color.opacity(0.35)))
            .clipShape(Capsule())
            .help(tooltip)
        }
    }

    private var color: Color {
        let h = model.headroomFraction
        if h > 0.5 { return .green }
        if h > 0.2 { return .yellow }
        return .red
    }

    private var tooltip: String {
        "Anthropic rate limit: \(model.remaining)/\(model.limit) RPM remaining. " +
        "Resets in \(model.resetSeconds)s. " +
        "Daemon will block new API calls when remaining ≤ 2."
    }
}
