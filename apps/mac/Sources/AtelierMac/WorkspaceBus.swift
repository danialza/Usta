import SwiftUI
import AtelierProto
import UserNotifications

/// Live workspace state derived from event bus + roles. Single source of truth
/// for "which role is ready, working, or done" — used by AssistantsGrid (step
/// badge color) and ActivityFeed (next-ready banner, fan-out hints).
@MainActor
final class WorkspaceBus: ObservableObject {
    @Published var events: [Atelier_V1_Event] = []
    @Published var roles: [Atelier_V1_Role] = []
    /// Event ids newly observed since last poll (UI highlights them).
    @Published var freshIds: Set<Int64> = []
    /// In-window toast queue (auto-clears after a few seconds).
    @Published var toasts: [ToastItem] = []
    /// Last set of "ready" role names — used to detect changes.
    private var lastReady: Set<String> = []
    /// Have we asked for notification permission?
    private var notifAuthRequested = false

    struct ToastItem: Identifiable, Equatable {
        let id = UUID()
        let kind: Kind
        let title: String
        let body: String
        enum Kind { case regen, ready, info }
    }

    func toast(kind: ToastItem.Kind, title: String, body: String) {
        let t = ToastItem(kind: kind, title: title, body: body)
        toasts.append(t)
        let tid = t.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_500_000_000)
            self?.toasts.removeAll { $0.id == tid }
        }
        // Also post as system notification (silent if user hasn't granted).
        ensureNotifAuth()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(identifier: tid.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    private func ensureNotifAuth() {
        if notifAuthRequested { return }
        notifAuthRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    enum RoleState: String { case pending, ready, working, done }

    /// Names of roles that have received a kickoff but haven't fully published
    /// yet — UI calls `markWorking(name)` on Send and the bus auto-clears
    /// once the role becomes .done.
    @Published var working: Set<String> = []

    func markWorking(_ name: String) { working.insert(name) }

    /// Loose topic match — `tests.passing` satisfies `qa.tests.passing` and
    /// vice-versa. Tolerates PM-side prefix mistakes so orchestration
    /// doesn't deadlock on naming drift.
    private static func topicMatches(_ wanted: String, in published: Set<String>) -> Bool {
        if published.contains(wanted) { return true }
        let suffix = wanted.split(separator: ".").last.map(String.init) ?? wanted
        for p in published {
            if p == wanted { return true }
            if p == suffix { return true }
            if p.hasSuffix("." + wanted) { return true }
            if wanted.hasSuffix("." + p) { return true }
            // last two segments must match (allow `ui.page.created` ~ `page.created`)
            let last2 = wanted.split(separator: ".").suffix(2).joined(separator: ".")
            if !last2.isEmpty && (p.hasSuffix(last2) || p == last2) { return true }
        }
        return false
    }

    /// Role lifecycle inferred from event log + working set.
    /// - .working if user fired its kickoff but it hasn't published all yet
    /// - .done if role published every topic in its `handoffPublishes` set
    /// - .ready if every subscribed topic has been published by SOMEONE
    /// - .pending otherwise
    func state(of name: String) -> RoleState {
        guard let r = roles.first(where: { $0.name == name }) else { return .pending }
        let allTopics = Set(events.map { $0.topic })
        let mineTopics = Set(events.filter { $0.fromRole == name }.map { $0.topic })
        let pubs = r.handoffPublishes
        let subs = r.handoffSubscribes
        let pubsDone = !pubs.isEmpty && pubs.allSatisfy { Self.topicMatches($0, in: mineTopics) }
        if pubsDone { return .done }
        if working.contains(name) { return .working }
        let subsMet = subs.isEmpty || subs.allSatisfy { Self.topicMatches($0, in: allTopics) }
        if subsMet { return .ready }
        return .pending
    }

    /// Group key for a role: prefix of first published topic
    /// (e.g. "ui.component.added" → "ui", "api.contract.defined" → "api").
    /// Roles in the same group are likely to touch overlapping code areas.
    func group(of name: String) -> String? {
        guard let r = roles.first(where: { $0.name == name }) else { return nil }
        let topics = r.handoffPublishes + r.handoffSubscribes
        return topics.first?.split(separator: ".").first.map(String.init)
    }

    /// Roles currently working that share a group with `candidate`.
    func conflicts(with candidate: String) -> [String] {
        guard let g = group(of: candidate) else { return [] }
        return working
            .filter { $0 != candidate && group(of: $0) == g }
            .sorted()
    }

    /// For a pending role, list its missing-upstream topics + which role
    /// would publish each. Used by the UI to explain "blocked on …".
    func missingFor(_ name: String) -> [(topic: String, from: String)] {
        guard let r = roles.first(where: { $0.name == name }) else { return [] }
        let published = Set(events.map { $0.topic })
        return r.handoffSubscribes
            .filter { !Self.topicMatches($0, in: published) }
            .map { topic in
                // Find producer with fuzzy match too.
                let pub = roles.first(where: { r in
                    r.handoffPublishes.contains(where: { Self.topicMatches(topic, in: [$0]) })
                })?.name ?? "?"
                return (topic, pub)
            }
    }

    /// Roles currently ready to act (have all upstream events) but not done.
    var readyNow: [String] {
        roles.map { $0.name }
            .filter { state(of: $0) == .ready }
    }

    /// For an event, which roles subscribe to its topic (auto-dispatch targets).
    func subscribers(of topic: String) -> [String] {
        roles
            .filter { $0.handoffSubscribes.contains(topic) }
            .map { $0.name }
    }

    private var pollTask: Task<Void, Never>? = nil
    private weak var client: AtelierClientModel?

    func start(workspaceID: String, client: AtelierClientModel, roles: [Atelier_V1_Role]) {
        self.client = client
        self.roles = roles
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.refresh(workspaceID: workspaceID)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if Task.isCancelled { break }
                await self?.refresh(workspaceID: workspaceID)
            }
        }
    }

    func stop() { pollTask?.cancel(); pollTask = nil }

    func updateRoles(_ rs: [Atelier_V1_Role]) { self.roles = rs }

    /// Trigger an immediate refresh outside the poll cadence (Refresh button).
    func refreshNow(workspaceID: String) {
        Task { await self.refresh(workspaceID: workspaceID) }
    }

    private func refresh(workspaceID: String) async {
        guard let client else { return }
        let fresh = await client.listEvents(workspaceID: workspaceID, limit: 200)
        let oldIds = Set(events.map { $0.id })
        let newIds = Set(fresh.map { $0.id }).subtracting(oldIds)
        events = fresh.sorted(by: { $0.id < $1.id })
        if !newIds.isEmpty {
            freshIds = newIds
            // Notify subscriber roles about each new event so their panes
            // can auto-regenerate their next-task kickoff.
            let newEvents = fresh.filter { newIds.contains($0.id) }
            var triggered: Set<String> = []
            for ev in newEvents {
                for r in roles where r.handoffSubscribes.contains(ev.topic) && r.name != ev.fromRole {
                    NotificationCenter.default.post(name: .atelierEventForRole, object: r.name)
                    triggered.insert(r.name)
                }
            }
            if !triggered.isEmpty {
                let names = triggered.sorted().map { "@\($0)" }.joined(separator: ", ")
                toast(kind: .regen,
                      title: "System updated next task",
                      body: "Regenerating for \(names) based on new events")
            }
            let toClear = newIds
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                self?.freshIds.subtract(toClear)
            }
        }
        // Ready-set change detector → "Next: @a, @b"
        let nowReady = Set(readyNow)
        let newlyReady = nowReady.subtracting(lastReady)
        if !newlyReady.isEmpty && !lastReady.isEmpty {
            // Skip on first tick (when lastReady is empty) to avoid spam at boot.
            let body = newlyReady.sorted().map { "@\($0)" }.joined(separator: ", ")
            toast(kind: .ready, title: "Ready to start", body: "Next: \(body)")
        }
        lastReady = nowReady
        // Drop "working" flag once role has published all its outputs.
        let stillWorking = working.filter { name in
            guard let r = roles.first(where: { $0.name == name }) else { return false }
            let mine = Set(events.filter { $0.fromRole == name }.map { $0.topic })
            let pubs = Set(r.handoffPublishes)
            return !(pubs.isSubset(of: mine) && !pubs.isEmpty)
        }
        if stillWorking != working { working = stillWorking }
    }
}
