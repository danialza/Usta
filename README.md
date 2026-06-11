<div align="center">

<img src="brand/usta-logo.png" alt="Usta" width="160" />

# Usta

### Your AI engineering team. Not an assistant.

*Most AI dev tools give you one helper.<br/>
**Usta gives you a team — that talks to itself.***

<p>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-22d3ee?style=for-the-badge&labelColor=050810"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15+-fbbf24?style=for-the-badge&logo=apple&logoColor=white&labelColor=050810">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-b794f4?style=for-the-badge&logo=swift&logoColor=white&labelColor=050810">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-stable-22d3ee?style=for-the-badge&logo=rust&logoColor=white&labelColor=050810">
</p>

<p>
  <strong>10+ specialist roles</strong> ·
  <strong>Shared event bus</strong> ·
  <strong>PM auto-orchestration</strong> ·
  <strong>Native macOS</strong>
</p>

</div>

---

## What it is

**Usta** ("master craftsman" in Turkish & Azerbaijani) is a native macOS IDE that runs a **panel of AI specialists in parallel** — each with its own role, system prompt, toolbelt, and live CLI session.

You don't pick the team. **A PM agent reads your project, decides which specialists it needs, and generates each role's brief on the fly.** A landing page might spawn a frontend, a designer, and an animation specialist. A trading backend might spawn an API engineer, a DBA, a security auditor, and QA. A docs site might just be writer + reviewer. Whatever the project asks for, the team is shaped to fit.

Roles aren't a fixed menu — they're proposed per workspace. Common ones the PM tends to draft:

> Frontend · Backend · UI/UX · Animation · QA · DevOps · DBA · Security · Docs · Mobile · Data · Research — and anything else the project actually needs.

They coordinate over a **shared event bus**. Frontend ships a component → publishes `ui.component.added` → QA wakes up, writes tests → publishes `tests.passing`. If tests fail, the responsible role gets reopened automatically.

You describe the project or feature once. The PM splits it across whichever specialists it picked. You watch the panes work.

---

## Why this exists

I spent months pair-programming with Claude on real projects. Every time it felt like I was talking to a brilliant assistant — never a *team*. Real projects aren't built by one person. Someone writes the spec. Someone codes the API. Someone tests. Someone deploys.

I wanted AI tooling that worked the same way. So I built it.

---

## Highlights

- ✅ **N Claude Code instances in parallel** — each in its own PTY, session persistence via `claude --continue`
- ✅ **Event bus** — roles publish/subscribe topics (`api.added`, `tests.passing`, `security.cleared`)
- ✅ **Auto-orchestration** — feature requests split across roles by a PM agent
- ✅ **Idle-watcher** — detects when a role finishes (PTY tail + file-change check) and publishes its events
- ✅ **Bottleneck detector** — when the bus deadlocks, the UI points at the role to unblock
- ✅ **Grill flow** — PM asks targeted clarifying questions before scaffolding so the team has real context
- ✅ **Rate-limit gate** — auto-adapts to your Anthropic tier from response headers; never burst-fails
- ✅ **Memory** — Claude Code sessions persist across pane restarts; scrollback replays from DB
- ✅ **MCP server** — `publish_event` + `list_events` exposed as MCP tools so external Claude instances can read/write the bus

---

## Quickstart

### Build from source

```bash
git clone https://github.com/danialza/atelier.git
cd atelier
bash scripts/build-mac.sh
open dist/Atelier.app
```

Requires macOS 15+, Xcode CLT, Rust stable.

### First run

1. **Settings → API Keys** — paste your Anthropic key (stored in macOS Keychain).
   If you use Claude Code with Pro/Max login, no key needed.
2. **New Project** — describe what you want to build in 1–3 sentences. PM proposes a team. Optionally hit **Refine with Grill** to answer targeted clarifying questions.
3. **Create** — Usta scaffolds the project, writes role yamls, and auto-orchestrates the kickoff.
4. **Watch the team** — open the suggested pane, click **Generate prompt**, hit Send. Events fire. Downstream roles wake up.

---

## Tech stack

| Layer | Tech |
|---|---|
| App | SwiftUI native, macOS 15+ |
| Daemon | Rust + tokio + tonic gRPC |
| Transport | gRPC over Unix Domain Socket |
| Terminal | SwiftTerm (real PTY) |
| Storage | SQLite (events, scrollback, role state) |
| LLM | Anthropic · Gemini · Ollama (pluggable) |
| MCP | Stdio server for external tool integration |

---

## Architecture

```
┌─────────────────────────────────────────┐
│  SwiftUI App   (one pane per role)      │
└──────────────┬──────────────────────────┘
               │ gRPC over UDS
               ▼
┌─────────────────────────────────────────┐
│  atelierd (Rust daemon)                 │
│  • PTY manager                          │
│  • Event bus (SQLite)                   │
│  • PM orchestrator (Anthropic client)   │
│  • Idle watcher                         │
│  • Role library (YAML)                  │
│  • MCP stdio server                     │
└─────────────────────────────────────────┘
```

---

## Repo layout

```
usta/
├── brand/                   logo + identity assets
├── proto/                   gRPC contract (single source of truth)
├── roles/                   builtin role YAMLs
├── crates/
│   ├── atelier-proto/       tonic-generated stubs
│   ├── atelier-core/        sqlite + pty manager + tool registry
│   ├── atelier-providers/   Anthropic + Gemini + Ollama (streaming)
│   ├── atelier-index/       fastembed + cosine search
│   ├── atelier-pm/          PM agent (orchestration + grill)
│   ├── atelier-roles/       role library
│   ├── atelier-mcp/         stdio MCP server
│   ├── atelier-daemon/      atelierd
│   └── atelier-cli/         ateliercli
├── apps/
│   └── mac/                 SwiftUI app
└── scripts/build-mac.sh
```

> **Note on naming.** Internal crates and the daemon binary are still `atelier-*` / `atelierd` from the prototype phase. The user-facing brand is **Usta**. The internal rename is deferred to avoid breaking existing Keychain entries + paths.

---

## Roadmap

- [ ] Linux + Windows
- [ ] Local-only mode (Ollama-backbone, no cloud)
- [ ] Role marketplace (share custom YAMLs)
- [ ] Cloud sync for the event log
- [ ] VS Code extension as alternative shell

---

## Contributing

PRs welcome. For non-trivial changes, open an issue first.

```bash
cargo build --release -p atelier-daemon   # daemon
bash scripts/build-mac.sh                 # full Mac bundle
```

See [CONTRIBUTING.md](CONTRIBUTING.md) when added.

---

## License

[MIT](LICENSE) for source code.<br/>
[TRADEMARK.md](TRADEMARK.md) for the **Usta** name and identity.

---

## Credits

Built by **[@danialza](https://github.com/danialza)** · [LinkedIn](https://www.linkedin.com/in/danialza/)

Standing on the shoulders of:
- [Anthropic Claude Code](https://anthropic.com) — the agent runtime
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — PTY rendering
- [tonic](https://github.com/hyperium/tonic) — gRPC for Rust

---

<div align="center">

**If Usta saves you time, give it a ⭐ — that's the fuel.**

</div>
