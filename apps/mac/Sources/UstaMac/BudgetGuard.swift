import SwiftUI
import UstaProto

/// Spend cap per workspace. The cost dashboard tells you what a run cost
/// *after* it ran; this is the part that speaks up while it's still running —
/// a warning at 80%, a hard stop at 100% that blocks new kickoffs until you
/// raise the cap or clear it.
@MainActor
final class BudgetGuard: ObservableObject {
    @Published private(set) var spent: Double = 0
    @Published var cap: Double {
        didSet { UserDefaults.standard.set(cap, forKey: Self.key(workspaceID)) }
    }
    /// Latched so the toast fires once per threshold crossing, not per poll.
    @Published private(set) var warned = false
    @Published private(set) var blocked = false

    private let workspaceID: String
    private var pollTask: Task<Void, Never>?

    static func key(_ ws: String) -> String { "usta.budget.\(ws)" }

    init(workspaceID: String) {
        self.workspaceID = workspaceID
        self.cap = UserDefaults.standard.double(forKey: Self.key(workspaceID))
    }

    var enabled: Bool { cap > 0 }
    var fraction: Double { cap > 0 ? min(1.5, spent / cap) : 0 }

    /// 0 = fine, 1 = past the warn line, 2 = over cap.
    var level: Int {
        guard enabled else { return 0 }
        if spent >= cap { return 2 }
        if spent >= cap * 0.8 { return 1 }
        return 0
    }

    var color: Color {
        switch level {
        case 2:  return UstaTheme.accentPink
        case 1:  return UstaTheme.accentAmber
        default: return UstaTheme.accentTeal
        }
    }

    /// Poll the real cost report. Scanning CLI session logs isn't free, so
    /// keep it slow — spend moves in dollars-per-minute at worst.
    func start(client: UstaClientModel, onCross: @escaping (Int, Double, Double) -> Void) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let r = await client.getCosts(workspaceID: self.workspaceID) {
                    let before = self.level
                    self.spent = r.totalUsd
                    let after = self.level
                    if after > before {
                        if after == 1 { self.warned = true }
                        if after == 2 { self.blocked = true }
                        onCross(after, self.spent, self.cap)
                    }
                    if after == 0 { self.warned = false; self.blocked = false }
                }
                try? await Task.sleep(nanoseconds: 45_000_000_000)
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    /// Called before anything that would spend more (Start Team, kickoff).
    /// Returns false when the cap is already blown.
    func allowsNewWork() -> Bool { !(enabled && spent >= cap) }

    func raiseCap(to newCap: Double) {
        cap = newCap
        if spent < newCap { blocked = false; warned = spent >= newCap * 0.8 }
    }
}

/// Toolbar chip: current spend against the cap. Click to edit the cap.
struct BudgetChip: View {
    @ObservedObject var guardModel: BudgetGuard
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Button { draft = guardModel.cap > 0 ? String(format: "%.2f", guardModel.cap) : ""; editing = true } label: {
            HStack(spacing: 5) {
                Image(systemName: guardModel.level == 2 ? "exclamationmark.triangle.fill" : "gauge.medium")
                    .font(.system(size: 10))
                if guardModel.enabled {
                    Text(String(format: "$%.2f / $%.0f", guardModel.spent, guardModel.cap))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                } else {
                    Text("Set budget").font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(guardModel.color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(guardModel.color.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(guardModel.color.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .help(guardModel.enabled
              ? "Spend cap for this workspace. New work is blocked once it's reached."
              : "No spend cap set for this workspace.")
        .popover(isPresented: $editing) { capEditor }
    }

    private var capEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Workspace spend cap")
                .font(.system(size: 13, weight: .semibold))
            Text("Usta warns at 80% and blocks new kickoffs at 100%. Costs are estimated from the CLIs' own session logs.")
                .font(.system(size: 11)).foregroundStyle(UstaTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("$").foregroundStyle(UstaTheme.dim)
                TextField("no limit", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { apply() }
                ForEach([5.0, 10.0, 25.0], id: \.self) { v in
                    Button("$\(Int(v))") { draft = String(format: "%.0f", v) }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            HStack {
                Button("Remove cap") { guardModel.raiseCap(to: 0); editing = false }
                    .buttonStyle(.plain).font(.system(size: 11))
                    .foregroundStyle(UstaTheme.dim)
                Spacer()
                Button("Save") { apply() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func apply() {
        guardModel.raiseCap(to: Double(draft.trimmingCharacters(in: .whitespaces)) ?? 0)
        editing = false
    }
}

/// Full-width banner shown once the cap is blown.
struct BudgetBanner: View {
    @ObservedObject var guardModel: BudgetGuard
    var onRaise: () -> Void

    var body: some View {
        if guardModel.level == 2 {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(UstaTheme.accentPink)
                Text(String(format: "Budget reached — $%.2f of $%.0f. New kickoffs are paused.",
                            guardModel.spent, guardModel.cap))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Button("Raise cap") { onRaise() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(UstaTheme.accentPink.opacity(0.14))
            .overlay(Rectangle().frame(height: 1)
                .foregroundStyle(UstaTheme.accentPink.opacity(0.4)), alignment: .bottom)
        }
    }
}
