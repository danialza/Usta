import Foundation
import SwiftUI
import UstaProto

/// Zero-key demo: scaffolds a demo workspace, imports a bundled 4-role team,
/// then replays a scripted handoff sequence onto the real event bus. The
/// user watches the activity feed + handoff graph + replay light up without
/// entering any API key or installing any CLI.
@MainActor
enum DemoRunner {
    static let demoDirName = "UstaDemo"

    static var demoPath: String {
        (FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(demoDirName)).path
    }

    /// Full run: workspace + team + scripted events (spread over ~20s).
    static func run(client: UstaClientModel) async -> Usta_V1_Workspace? {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: demoPath, withIntermediateDirectories: true)
        // A tiny real file so the workspace isn't an empty void.
        let readme = demoPath + "/README.md"
        if !fm.fileExists(atPath: readme) {
            try? demoReadme.write(toFile: readme, atomically: true, encoding: .utf8)
        }
        await client.openWorkspace(path: demoPath)
        guard let ws = client.workspaces.first(where: { $0.path == demoPath }) else { return nil }
        _ = await client.importTeam(workspaceID: ws.id, yaml: demoTeamYAML, replace: true)
        // Fire the scripted story in the background; the user watches live.
        let wsID = ws.id
        Task {
            for (delaySec, role, topic, summary) in demoScript {
                try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
                _ = await client.publishEvent(workspaceID: wsID, fromRole: role,
                                              topic: topic, summary: summary)
            }
        }
        return ws
    }

    /// (delay-before-seconds, role, topic, summary)
    private static let demoScript: [(Double, String, String, String)] = [
        (1.0, "product-manager", "feature.requested",
         "Demo: build a landing page with a waitlist form — split across the team."),
        (3.0, "product-manager", "kickoff.plan.ready",
         "Plan ready: backend builds /api/waitlist, frontend builds the page, qa verifies end-to-end. See docs/PLAN.md."),
        (4.0, "backend", "api.ready",
         "POST /api/waitlist accepting {email}, stores to SQLite, returns 201. Validation + rate limit in. Docs in docs/API.md."),
        (4.0, "frontend", "ui.ready",
         "Landing page live: hero, feature grid, waitlist form wired to /api/waitlist with optimistic UI + error states."),
        (3.5, "qa", "issue.reported",
         "Duplicate email returns 500 — expected 409 with friendly message. Repro: submit same email twice."),
        (3.5, "backend", "api.ready",
         "Fixed: unique-constraint now mapped to 409 + client message. Added regression test."),
        (3.0, "qa", "qa.report.ready",
         "End-to-end pass: 12/12 cases green (happy path, dupes, invalid emails, empty form, mobile layout). Ship it."),
    ]

    private static let demoReadme = """
    # Usta Demo Workspace

    This folder was created by Usta's demo mode. The events you're watching
    are a scripted replay of a real team run — no API key needed.

    Connect your Anthropic / OpenAI / Gemini key in Settings and press
    "Start Team" to run the real thing.
    """

    /// 4-role demo team (same shape as templates/web-app-team.ustateam.yaml).
    private static let demoTeamYAML = """
    usta_template: 1
    name: demo-team
    description: Demo team for the zero-key walkthrough.
    roles:
    - name: product-manager
      emoji: "🧭"
      description: breaks the idea into tasks and routes work
      system_prompt: You are the product manager. Plan lean, publish kickoff.plan.ready.
      default_provider: anthropic
      default_model: claude-sonnet-4-6
      allowed_tools: [fs_read, fs_write]
      handoff_topics:
        publishes: [kickoff.plan.ready]
        subscribes: [feature.requested, qa.report.ready]
      cli_command: claude
      kickoff: Write docs/PLAN.md then publish kickoff.plan.ready.
      autonomy: manual
    - name: frontend
      emoji: "🎨"
      description: builds the UI
      system_prompt: You are the frontend engineer.
      default_provider: anthropic
      default_model: claude-sonnet-4-6
      allowed_tools: [fs_read, fs_write]
      handoff_topics:
        publishes: [ui.ready]
        subscribes: [kickoff.plan.ready, api.ready]
      cli_command: claude
      kickoff: Build the page per docs/PLAN.md, publish ui.ready.
      autonomy: manual
    - name: backend
      emoji: "⚙️"
      description: builds the API
      system_prompt: You are the backend engineer.
      default_provider: anthropic
      default_model: claude-sonnet-4-6
      allowed_tools: [fs_read, fs_write]
      handoff_topics:
        publishes: [api.ready]
        subscribes: [kickoff.plan.ready]
      cli_command: claude
      kickoff: Build the API per docs/PLAN.md, publish api.ready.
      autonomy: manual
    - name: qa
      emoji: "🧪"
      description: verifies end to end
      system_prompt: You are QA.
      default_provider: anthropic
      default_model: claude-sonnet-4-6
      allowed_tools: [fs_read, fs_write]
      handoff_topics:
        publishes: [qa.report.ready, issue.reported]
        subscribes: [ui.ready, api.ready]
      cli_command: claude
      kickoff: Test the app, publish qa.report.ready or issue.reported.
      autonomy: manual
    """
}
