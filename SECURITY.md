# Security Policy

## Reporting a vulnerability

Email **danial.zaferanchi@gmail.com** with details. Do not open a public issue.

I'll respond within a few days and credit you in the fix unless you ask otherwise.

## Scope

- Daemon (`atelier-daemon`) — gRPC over Unix domain socket, local-only by default
- CLI (`atelier`)
- MCP server (`atelier-mcp`) — stdio
- Mac app

## What's in scope

- Anything that lets a non-owner of the UDS read/write events, scrollback, or API keys.
- Anything that escapes the workspace sandbox (path traversal, command injection in role scripts, etc.).
- Keychain handling regressions.
- Prompt-injection paths that result in arbitrary code execution beyond what the agent terminal already allows.

## Out of scope

- Anything that requires a malicious LLM provider you intentionally configured.
- DoS by feeding huge files / infinite loops to your own daemon.
