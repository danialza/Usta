# Usta v0.1.0 — first public release

> Your AI engineering team. Not an assistant.

Usta is a native macOS IDE where you don't talk to one AI. You talk to a **team** — a PM agent plans the work, specialist roles (frontend, backend, DB, QA, security, devops, designer…) run in their own terminals, and they hand work off through a shared event bus.

## ✨ Highlights

- **Multi-agent orchestration** — PM auto-plans which roles act on each request and assigns scoped tasks.
- **Real terminals per role** — SwiftTerm PTY, persistent scrollback across daemon restarts.
- **Pluggable LLMs** — Anthropic, Gemini, local Ollama. Local-first is real.
- **Shared event bus** — SQLite-backed, fuzzy topic matching, auto inter-agent reactions.
- **Bottleneck detector** — global "Next Action" bar always shows you what to unblock.
- **Idle watcher** — daemon detects when a role finishes and publishes its announcements.
- **MCP server included** — drive Usta from any MCP-compatible client.
- **Skills system** — caveman, memory, mattpocock catalog, custom.
- **Diff view** for `fs_edit` / `fs_write` tool calls.
- **Keychain-backed** API key storage. Keys never touch disk.

## 🔧 Stack

SwiftUI (macOS 15+) · Swift 6 · Rust + tokio · tonic gRPC over UDS · SQLite · MCP stdio.

## 📦 Install

1. Download `Usta.dmg` below.
2. Drag **Usta.app** into Applications.
3. Launch — daemon auto-spawns on first open.

Or build from source — see [README](https://github.com/danialza/atelier#readme).

## 🐛 Known limitations

- macOS only (Linux/Windows tracked).
- No remote/web frontend.
- Community role marketplace not yet shipped.

## 🙏 Credits

Built solo by [@danialza](https://www.linkedin.com/in/danialza/). MIT licensed. Standing on the shoulders of SwiftTerm, tonic, Anthropic, Google, and the Ollama community.

Found a bug? [Open an issue](https://github.com/danialza/atelier/issues/new/choose).
Liked it? A ⭐ helps a lot.
