<div align="center">

<img src="brand/usta-logo.png" alt="Usta" width="160" />

# Usta

### Your AI engineering team. Not an assistant.

*Most AI dev tools give you one helper.*<br/>
***Usta gives you a team — that talks to itself.***

<p>
  <a href="LICENSE"><img alt="License" src="https://img.shields.io/badge/license-MIT-22d3ee?style=for-the-badge&labelColor=050810"></a>
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15+-fbbf24?style=for-the-badge&logo=apple&logoColor=white&labelColor=050810">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-b794f4?style=for-the-badge&logo=swift&logoColor=white&labelColor=050810">
  <img alt="Rust" src="https://img.shields.io/badge/Rust-stable-22d3ee?style=for-the-badge&logo=rust&logoColor=white&labelColor=050810">
</p>

<p>
  <strong>Dynamic specialist team</strong> ·
  <strong>Shared event bus</strong> ·
  <strong>PM auto-orchestration</strong> ·
  <strong>Native macOS</strong>
</p>

<br/>

<img src="brand/screenshots/guide/08-workspace-hero.png" alt="Usta workspace — a full team of specialist agents working in parallel on one project, coordinating through a shared event bus" width="100%" />

<sub><strong>One workspace. A full team of specialists. One shared event bus.</strong></sub>

<br/><br/>

<p>
  <a href="https://github.com/danialza/Usta/releases"><strong>↓ Download for macOS</strong></a> ·
  <a href="https://usta-ai.vercel.app"><strong>🌐 Website</strong></a> ·
  <a href="https://usta-ai.vercel.app/guide.html"><strong>📖 Visual Guide</strong></a>
</p>

</div>

---

## What is Usta?

**Usta** ("master craftsman" in Turkish & Azerbaijani) is a native macOS IDE that runs a **panel of AI specialists in parallel** — each with its own role, system prompt, toolbelt, and live CLI session. They don't take turns. They work together.

You describe a project once. A **PM agent** reads it, decides which specialists are needed (frontend, backend, DBA, QA, security, designer, animator, devops, docs — whatever the project actually calls for), writes each role's brief on the fly, and launches them as separate terminals. They coordinate through a **shared event bus**: frontend ships a component → QA wakes up and writes tests → tests pass → done. If tests fail, the right role gets reopened automatically.

You stop being the project manager. You ship the feature. The team ships the diff.

> 📖 **[See the full visual guide → usta-ai.vercel.app/guide.html](https://usta-ai.vercel.app/guide.html)**
> Ten illustrated steps showing exactly how to go from idea to a working team. Real screenshots.

---

## Why this exists

I spent months pair-programming with Claude on real projects. Every time it felt like I was talking to a brilliant assistant — never a *team*. Real projects aren't built by one person. Someone writes the spec. Someone codes the API. Someone tests. Someone deploys. The handoffs are the work.

I wanted AI tooling that worked the same way. So I built it.

---

## Highlights

- 🧠 **PM auto-orchestration** — the team is shaped to fit your project, not picked from a fixed menu.
- 🔀 **Shared event bus** — SQLite-backed pub/sub, fuzzy topic match, auto inter-agent reactions.
- ⚡ **Real PTYs per role** — SwiftTerm, persistent scrollback, survives daemon restarts.
- 👁 **Idle watcher** — daemon detects when a role finishes and publishes its announcements.
- 🚧 **Bottleneck detector** — global "Next Action" bar always tells you which role to unblock next.
- 🔌 **Pluggable LLMs** — Anthropic, Gemini, local Ollama. Per-role. Local-first is real.
- 🛠 **MCP server included** — drive Usta's bus from any MCP-compatible client.
- 🔐 **Keychain-backed** — API keys never touch disk.
- 🎯 **Skills system** — `caveman`, `memory`, `grill`, `tdd`, `diagnose` — pre-loaded, one-click invoke.
- 📐 **Grill flow** — PM asks sharp clarifying questions *before* scaffolding so the team has real context.

---

## Install

**Step 1 — Download & install**

Grab the latest `Usta-macOS.dmg` from [Releases](https://github.com/danialza/Usta/releases). Open it and drag **Usta.app** into your **Applications** folder.

**Step 2 — Run this command in Terminal**

```
xattr -dr com.apple.quarantine /Applications/Usta.app
```

**Step 3 — Launch the app**

Open **Usta** from Applications (or Spotlight). The daemon spawns automatically.

> 📖 First time? Walk through the full 10-step guide: **[usta-ai.vercel.app/guide.html](https://usta-ai.vercel.app/guide.html)**

---

## Tech stack

SwiftUI (macOS 15+) · Swift 6 concurrency · Rust + tokio daemon · tonic gRPC over Unix Domain Socket · SwiftTerm (real PTYs) · SQLite (events, scrollback, role state) · Anthropic / Gemini / Ollama (pluggable per role) · MCP stdio server.

---

## Roadmap

- [ ] Linux + Windows
- [ ] Fully local-only mode (Ollama-backbone, no cloud)
- [ ] Community role marketplace (share custom YAMLs)
- [ ] Cloud sync for the event log
- [ ] VS Code extension as alternative shell

---

## Contributing

PRs welcome. For non-trivial changes, open an issue first. See **[CONTRIBUTING.md](CONTRIBUTING.md)**.

---

## License & trademark

Code: **[MIT](LICENSE)**.
The **Usta** name and visual identity: **[TRADEMARK.md](TRADEMARK.md)**.

---

## Credits

Built by **[@danialza](https://github.com/danialza)** · [LinkedIn](https://www.linkedin.com/in/danialza/)

Standing on the shoulders of [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), [tonic](https://github.com/hyperium/tonic), Anthropic Claude Code, Google Gemini, and the Ollama community.

---

<div align="center">

### If Usta saves you time, **give it a ⭐**
*That's the fuel.*

<br/>

[**↓ Download for macOS**](https://github.com/danialza/Usta/releases) · [**🌐 Website**](https://usta-ai.vercel.app) · [**📖 Guide**](https://usta-ai.vercel.app/guide.html)

</div>
