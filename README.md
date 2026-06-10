<div align="center">

<img src="brand/logo-lockup.svg" alt="Usta — AI engineering team" width="380" />

<h3>Your AI engineering team. Not an assistant.</h3>

<p>
  <em>Most AI dev tools give you one helper.<br/>
  <strong>Usta gives you a team — that talks to itself.</strong></em>
</p>

<p>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/License-MIT-22d3ee?style=for-the-badge&labelColor=0d0e17"></a>
  <img alt="macOS" src="https://img.shields.io/badge/macOS-15+-fbbf24?style=for-the-badge&logo=apple&logoColor=white&labelColor=0d0e17">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6-b794f4?style=for-the-badge&logo=swift&logoColor=white&labelColor=0d0e17">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-1.80-22d3ee?style=for-the-badge&logo=rust&logoColor=white&labelColor=0d0e17">
</p>

<p>
  <strong>10+ specialist roles</strong> &nbsp;·&nbsp;
  <strong>Real event bus</strong> &nbsp;·&nbsp;
  <strong>Auto-orchestration</strong> &nbsp;·&nbsp;
  <strong>100% native macOS</strong>
</p>

</div>

---

## What it is

**Usta** ("master craftsman" in Turkish & Azerbaijani) is a native macOS
IDE that runs multiple AI agents as a real engineering team.

Instead of chatting one-on-one with a single AI assistant, you get a
panel of specialists working in parallel — each with its own role,
system prompt, toolbelt, and live CLI session:

- 🎨 **Frontend** — UI components, layouts, accessibility
- ⚙️ **Backend** — APIs, business logic, integrations
- 🧠 **Product Manager** — scope, roadmap, prioritization
- 🎭 **UI/UX** — design tokens, specs, wireframes
- 🔒 **Security** — OWASP audits, auth, threat models
- 🧪 **QA** — e2e tests, regression, coverage
- 🚀 **DevOps** — CI/CD, deploys, observability
- 🗄️ **DBA** — schema, migrations, query perf
- ✨ **Animation Specialist** — Framer Motion, GSAP
- 📚 **Docs** — API refs, onboarding guides

They coordinate over an **event bus**: when frontend finishes a component
it publishes `ui.component.added`; QA wakes up, writes tests, publishes
`tests.passing`. If tests fail, backend gets reopened automatically.

You don't drive each one — the **PM agent** does. You say *"build me a
contact form with admin panel"*, PM splits it across the team, and you
watch ten panes do the work.

## Quickstart

### Build from source

```bash
git clone https://github.com/USERNAME/usta.git
cd usta
bash scripts/build-mac.sh
open dist/Atelier.app
```

### First run

1. **Settings → API Keys** — add your Anthropic key (stored in Keychain).
   If you use Claude Code with Pro/Max login, no key needed.
2. **New Project** — describe what you want to build in 1-3 sentences.
   PM proposes the team. Hit **Refine with Grill** to answer targeted
   clarifying questions before scaffolding.
3. **Create** — Usta scaffolds the project, writes role yamls, and
   auto-orchestrates the kickoff.
4. **Watch the team** — open the suggested pane, click **Generate
   prompt**, hit Send. Events fire, downstream roles wake up.

## Why I built this

I spent months pair-programming with Claude on real projects. Every
time I felt I was talking to a brilliant assistant — never a *team*.
Real projects aren't built by one person. Someone writes the spec.
Someone codes the API. Someone tests. Someone deploys.

I wanted AI tooling that felt the same way. So I built it.

Usta lets each pane think only about its slice. They hand off through
events. When QA finds a bug, backend gets reopened — no human nag
required. It's still early, but it's the workflow I'd been chasing.

## Tech stack

| Layer | Tech |
|---|---|
| App | SwiftUI native, macOS 15+ |
| Daemon | Rust + tokio + tonic gRPC |
| Transport | gRPC over Unix Domain Socket |
| Terminal | SwiftTerm (real PTY) |
| Storage | SQLite (events, scrollback, role state) |
| LLM | Anthropic / Gemini / Ollama (pluggable) |
| MCP | Stdio server for external tool integration |

## Architecture

```
┌─────────────────────────────────────────┐
│  SwiftUI App (one pane per role)        │
└──────────────┬──────────────────────────┘
               │ gRPC over UDS
               ▼
┌─────────────────────────────────────────┐
│  atelierd (Rust daemon)                 │
│  - PTY manager                          │
│  - Event bus (SQLite-backed)            │
│  - PM orchestrator (Anthropic client)   │
│  - Idle watcher (auto-detect handoffs)  │
│  - Role library (YAML loader)           │
│  - MCP stdio server                     │
└─────────────────────────────────────────┘
```

## Layout

```
usta/
├── brand/                     logo + identity assets
├── proto/                     gRPC contract (single source of truth)
├── roles/                     builtin role YAMLs
├── crates/
│   ├── atelier-proto/         tonic-generated stubs
│   ├── atelier-core/          db (sqlite), pty manager, tool registry
│   ├── atelier-providers/     Anthropic + Gemini + Ollama with streaming
│   ├── atelier-index/         fastembed + cosine search
│   ├── atelier-pm/            PM agent (orchestration + grill)
│   ├── atelier-roles/         role library (builtin / user / workspace)
│   ├── atelier-mcp/           stdio MCP server
│   ├── atelier-daemon/        atelierd
│   └── atelier-cli/           ateliercli
├── apps/
│   └── mac/                   SwiftUI app
└── scripts/build-mac.sh       assemble dist/Atelier.app
```

## Highlights

- ✅ **Multi-agent runtime** — N Claude Code instances side-by-side,
  each in its own PTY with session persistence (`claude --continue`)
- ✅ **Event bus** — roles publish/subscribe topics (`api.added`,
  `tests.passing`, `security.cleared`). One source of truth.
- ✅ **Auto-orchestration** — feature requests get split across roles
  by a PM agent. Each affected role gets a concrete next task.
- ✅ **Idle watcher** — detects when a role has finished and publishes
  its events automatically (PTY tail + file change check)
- ✅ **Bottleneck detector** — when the bus deadlocks, UI points at the
  role to manually unblock
- ✅ **Grill flow** — PM asks targeted clarifying questions before
  scaffolding so the team has real context, not generic defaults
- ✅ **Rate-limit gate** — auto-adapts to Anthropic tier from response
  headers; never burst-fails
- ✅ **Memory** — Claude Code sessions persist across pane restarts;
  scrollback replays from DB
- ✅ **MCP** — `publish_event` and `list_events` exposed as MCP tools
  so external Claude instances can read/write the bus

## Notes on the repo name

The repository was originally named **Atelier** and some internal paths
(`atelierd`, `AtelierMac`, `dev.atelier.Atelier` bundle ID,
`dist/Atelier.app`) still use the old name to avoid breaking existing
installs and Keychain entries. The user-facing brand, license, and
trademark are **Usta**.

## Roadmap

- [ ] Linux + Windows
- [ ] Local-only mode with Ollama backbone
- [ ] Role marketplace (share custom YAMLs)
- [ ] Cloud sync for event log
- [ ] VS Code extension as alternative shell

## Contributing

PRs welcome. For non-trivial changes, open an Issue first.

```bash
# Daemon
cargo build --release -p atelier-daemon

# Mac app
bash scripts/build-mac.sh
```

## License

[MIT](LICENSE) for source code.
[TRADEMARK.md](TRADEMARK.md) for the **Usta** name and brand.

## Credits

Built by [@danialza](https://github.com/danialza).

Standing on the shoulders of:
- [Anthropic](https://anthropic.com) — Claude Code
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — PTY rendering
- [tonic](https://github.com/hyperium/tonic) — gRPC for Rust

If Usta saves you time, give it a ⭐ — that's the fuel.
