# Atelier

Multi-agent desktop development environment. Each terminal is a specialist AI
engineer with its own role, model, and permissions. A PM agent reads your
codebase and proposes a team tailored to the project; the proposed roles are
persisted as YAML in `<project>/.atelier/roles/` so the team evolves with the
codebase.

**Status:** Phase 3 — macOS app on top of the daemon/CLI core.

## Layout

```
atelier/
├── proto/                       gRPC contract (single source of truth)
├── roles/                       5 builtin role YAMLs (frontend/backend/...)
├── crates/
│   ├── atelier-proto/           tonic-generated stubs
│   ├── atelier-core/            db (sqlite), pty manager, tool registry
│   ├── atelier-providers/       Anthropic + Ollama with streaming
│   ├── atelier-index/           fastembed + cosine search
│   ├── atelier-pm/              PM agent (workspace summary + JSON team)
│   ├── atelier-roles/           role library (builtin / user / workspace)
│   ├── atelier-daemon/          atelierd
│   └── atelier-cli/             ateliercli
├── apps/
│   └── mac/                     SwiftUI app (grpc-swift-2 over UDS)
└── scripts/build-mac.sh         assemble dist/Atelier.app
```

## Quick start (CLI)

```bash
cargo build
./target/debug/ateliercli daemon start
./target/debug/ateliercli use <path/to/project>
./target/debug/ateliercli team apply               # PM proposes + persists team
./target/debug/ateliercli team chat "@security review login"
./target/debug/ateliercli term new                 # spawn a real pty
```

Set `ANTHROPIC_API_KEY` in the daemon's env (export then `daemon start`).

## Quick start (Mac app)

```bash
# dev: run alongside the rust target dir
cargo build
swift build --package-path apps/mac
./apps/mac/.build/debug/AtelierMac
# Atelier auto-starts atelierd from target/debug/atelierd if missing.

# release: assemble the .app bundle
./scripts/build-mac.sh
open dist/Atelier.app
```

The app's Settings sheet lets you change the socket path, paste an
ANTHROPIC_API_KEY (passed to the daemon it spawns), and toggle auto-start.

## License

MIT OR Apache-2.0.
