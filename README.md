# Atelier

Multi-agent desktop dev environment. Each terminal = one specialist AI engineer with own role, model, and permissions.

**Status:** Phase 1 / Week 1 — workspace bootstrap, gRPC skeleton, CLI ping.

## Layout

```
atelier/
├── proto/                  # gRPC contracts
├── crates/
│   ├── atelier-proto/      # generated stubs
│   ├── atelier-core/       # business logic
│   ├── atelier-providers/  # LLM provider abstraction
│   ├── atelier-daemon/     # the long-running service (atelierd)
│   └── atelier-cli/        # ateliercli — dev/test client
└── Cargo.toml
```

## Build

```bash
cargo build
```

## Run

Terminal A:
```bash
cargo run -p atelier-daemon
```

Terminal B:
```bash
cargo run -p atelier-cli -- ping
```

## License

MIT OR Apache-2.0.
