# PersistentShell agent guide

- `PersistentShell` is an SSH-only runtime. Do not add a local process backend,
  PTY, TUI, filesystem abstraction, job subsystem, or automatic command replay.
- Keep the core independent of AnyLanguageModel, MCP, SwiftChat, Keychain, and UI.
- `PersistentShellTool` and `PersistentShellMCP` are adapters over the same core
  semantics. Swift hosts use the native Tool directly and must not loop it through MCP.
- A timeout, cancellation, disconnect, channel failure, or framing failure invalidates
  the complete shell. The next call may establish a new shell, but the failed command is
  never replayed.
- Never log commands, output, passwords, private keys, or host-key confirmation data.
- Run `swift format lint --recursive Sources Tests Package.swift`, `swift test`, and
  `git diff --check` for source changes. Real OpenSSH checks are opt-in integration
  evidence and do not replace deterministic tests.
