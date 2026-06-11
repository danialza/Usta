# Show HN draft

## Title (one of)

- Show HN: Usta — a native macOS IDE where AI agents work as a team, not a single assistant
- Show HN: Usta – multi-agent IDE for macOS (SwiftUI + Rust, MIT)

## Body

Hi HN — I'm Danial. I've been building Usta for the last few months and I'm finally shipping it.

The premise: every AI coding tool I've used is a *single* agent. Cursor, Copilot, Claude Code — one model, one chat, one context. Real engineering at a company isn't one person. It's a PM splitting a feature, a backend dev, a frontend dev, a QA pass, sometimes a designer or security review. They hand work off through tickets, PRs, and Slack.

Usta tries to model that:

- A **PM agent** reads your idea or new-feature request, drafts a plan, picks which specialist roles are needed (frontend / backend / database / QA / security / devops / designer / docs / data / mobile…), and assigns tasks.
- Each role lives in its **own real PTY** (SwiftTerm), and you can run any CLI per role — Claude Code, Gemini CLI, `ollama run`, or whatever you want. Pluggable.
- They communicate through a **shared event bus** (SQLite-backed) — when role A publishes `auth.api.ready`, role B subscribed to that topic gets notified, sees the announcement injected into its prompt, and acts.
- An **idle watcher** in the daemon detects when a role goes quiet and confirms completion by looking at the announcements in its terminal output.
- A **bottleneck detector** finds the next blocked role and surfaces a "Next Action" globally so you always know what to do.

Stack:
- **App:** SwiftUI, macOS 15+, Swift 6 concurrency.
- **Daemon:** Rust + tokio + tonic gRPC over a Unix domain socket.
- **Storage:** SQLite for events, scrollback, role state.
- **LLM providers:** Anthropic, Gemini, Ollama. Local-first is real — point a workspace at Ollama and nothing leaves your machine.
- **MCP:** stdio server so external tools can drive Usta.
- **Keychain:** API keys never touch disk.

What's actually working today (v0.1.0):
- Multi-role orchestration with auto-handoff.
- New-feature flow: type a sentence, PM re-plans, only the affected roles wake up.
- Per-role persistent PTY + scrollback survives daemon restart.
- Skills system (mattpocock's, caveman mode, custom).
- Diff view for `fs_edit` / `fs_write` tool calls.
- Notifications + bottleneck detection.

What's not there yet:
- Linux/Windows. macOS only for now (SwiftUI native).
- Web/remote frontend.
- A polished marketplace for community roles.

The repo has the daemon, CLI, MCP server, and Mac app. MIT licensed. Build script + a signed .dmg in releases.

I'd love feedback on: the multi-agent model itself (is the event-bus + PM-orchestrator design the right primitive?), the role schema, and what's missing for it to replace your current setup.

Repo: https://github.com/danialza/atelier

Happy to answer anything.
