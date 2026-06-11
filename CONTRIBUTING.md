# Contributing to Usta

Thanks for the interest. PRs, issues, and ideas are all welcome.

## Before you start

- **Big changes:** open an issue first so we can agree on direction before code is written.
- **Small fixes:** typos, doc tweaks, obvious bugs — PR straight in.
- Code should compile clean (no new warnings) and existing tests should pass.

## Dev setup

```bash
# 1. Daemon + CLI (Rust)
cargo build --release -p usta-daemon
cargo build --release -p usta-cli
cargo build --release -p usta-mcp

# 2. Mac app (Swift)
bash scripts/build-mac.sh
open dist/Usta.app
```

Requirements: macOS 15+, Xcode CLT, Rust stable.

## Layout (where to put what)

- New role behaviour → `crates/usta-roles/`
- New LLM provider → `crates/usta-providers/`
- gRPC API change → edit `proto/usta.proto` first, then regenerate
- UI work → `apps/mac/Sources/UstaMac/`
- PM agent prompts → `crates/usta-pm/src/`

## Style

- Rust: `cargo fmt` + `cargo clippy -- -D warnings`
- Swift: match the surrounding style. No formatter enforced.
- Commits: `type(scope): subject` — `feat(pm): add grill refinement`, `fix(idle-watcher): ansi strip`. Imperative, lowercase, no trailing period.

## Reporting bugs

Use the issue template. Include:
- macOS version
- How you launched (script / .app / source)
- Steps to reproduce
- Logs from `~/Library/Logs/Usta/ustad.log` if relevant

## Security

If you find a security issue, **do not open a public issue**. Email `danial.zaferanchi@gmail.com` first.

## License

By contributing you agree your code is licensed under the project's [MIT License](LICENSE) and that you have the right to submit it.
