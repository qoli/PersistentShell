# PersistentShell

`PersistentShell` is an SSH-only persistent command shell for Swift on Apple platforms
and Linux. One actor owns one SSH connection, one long-lived session child channel, and
one `/bin/sh` process. Successive commands retain working directory, exported environment,
supported shell functions, activated environments, and background processes.

The package deliberately has no local-process backend, PTY, TUI support, public shell or
execution IDs, job subsystem, filesystem abstraction, Keychain/UI dependency, or automatic
command replay.

## Products

```text
PersistentShell        SSH runtime and host-key/identity contracts
PersistentShellTool    native AnyLanguageModel.Tool named shell
PersistentShellMCP     MCP tools/list and tools/call adapter
persistent-shell-mcp   optional stdio MCP executable
```

The dependency direction is one-way:

```text
PersistentShellTool ─┐
                     ├─> PersistentShell ─> swift-nio-ssh 0.15+
PersistentShellMCP  ─┘
```

Core does not know AnyLanguageModel, MCP, SwiftChat, conversations, Keychain, or UI.
Native Swift hosts should inject `PersistentShellTool` directly and must not route it
through a local MCP subprocess.

## Installation

The package requires Swift 6.3 or newer through AnyLanguageModel 0.16. Apple
deployment targets remain macOS 14 and iOS 17. Swift 6.3 and Linux are not newly
verified by the SwiftChat 5ML-104 synchronization run on Xcode 27 / Swift 6.4.

Add the package through Swift Package Manager:

```swift
.package(
  url: "https://github.com/qoli/PersistentShell.git",
  branch: "main"
)
```

Use the `PersistentShell` core product, `PersistentShellTool` for native
AnyLanguageModel integration, or `PersistentShellMCP` for MCP hosts. Until the first
semantic-version tag is published, consumers should retain their resolved commit.

## Core usage

Generate an Ed25519 key in the host, persist its raw private representation in the host's
credential store, and pass only an in-memory identity into the package:

```swift
import PersistentShell

let identity = SSHIdentity.generateEd25519()
let pinnedKey = try SSHHostKey(
  authorizedKey: "ssh-ed25519 AAAA..."
)
let profile = SSHProfile(
  host: "build.example.com",
  username: "builder",
  hostKeyValidator: PinnedSSHHostKeyValidator(expected: pinnedKey)
)
let shell = PersistentShell(profile: profile, identity: identity)

let first = try await shell.execute("cd /srv/project && export MODE=release")
let second = try await shell.execute("pwd; printf '%s' \"$MODE\"")
await shell.close()
```

`execute` calls are serialized. Each call uses a private random nonce marker on stdout to
detect completion and obtain the exact shell exit status. Stdout and stderr remain separate
in `ShellResult`; `modelOutput` renders both plus `[Command finished with exit code N]`.
The configurable `maximumOutputBytes` caps combined captured bytes and reports how many
stdout/stderr bytes were omitted.

The implementation requests one non-PTY `ExecRequest("/bin/sh")`. This avoids terminal
control sequences and startup prompt/RC output while retaining POSIX shell state. Commands
that require a PTY or full-screen terminal are outside V1.

## Failure contract

Timeout, task cancellation, disconnect, child-channel failure, a missing/invalid marker,
or protocol desynchronization invalidates the complete SSH shell. The command outcome is
reported as unknown. The package never repairs that channel and never replays the command.
The next `execute` lazily creates a fresh SSH connection and shell. `reset()` performs the
same explicit invalidation; `close()` permanently closes the actor.

Background processes share the shell. They should redirect stdout and stderr because output
emitted during a later foreground call can legitimately appear in that call's streams.

## Host-key trust and bootstrap

`SSHHostKeyValidating` is a host-supplied trust seam. The package includes exact pinning and
`TrustOnFirstUseSSHHostKeyValidator`. TOFU requires both a host-owned
`SSHHostKeyPinningStore` and an explicit confirmation closure. The first confirmed key is
saved; a later key change hard-fails. The host exposes a reset action by calling its pinning
store's `resetPinnedKey` method. Core does not use `known_hosts`, `UserDefaults`, or Keychain.

For password bootstrap, construct `SSHIdentity(password:)`, connect through SSH, install the
generated identity's `authorizedKey()` using a bounded host-owned flow, close that bootstrap
shell, and reconnect with `SSHIdentity(ed25519PrivateKeyRawRepresentation:)`. Do not persist
the password. The real OpenSSH acceptance test exercises exactly this transition when
`PERSISTENT_SHELL_OPENSSH_PASSWORD` is present.

## AnyLanguageModel Tool

```swift
import AnyLanguageModel
import PersistentShellTool

let shellTool = PersistentShellTool(shell: shell)
let session = LanguageModelSession(
  model: model,
  tools: [shellTool],
  transcript: transcript
)
```

The Tool is named `shell`. Its schema has exactly one required string property, `command`,
with `additionalProperties: false`. Keep the same `PersistentShellTool` (and therefore the
same actor) when rebuilding a `LanguageModelSession`; shell state must outlive an immutable
tool snapshot. SwiftChat's conversation-owned Harness integration is intentionally a
separate application task.

## MCP adapter and executable

`PersistentShellMCPAdapter` registers the same `shell` definition and invokes the same actor.
The stdio executable requires an exact host-key pin and one identity:

```text
PERSISTENT_SHELL_HOST
PERSISTENT_SHELL_PORT                         # default 22
PERSISTENT_SHELL_USER
PERSISTENT_SHELL_HOST_KEY                     # OpenSSH public-key form
PERSISTENT_SHELL_PRIVATE_KEY_BASE64            # preferred: raw 32-byte Ed25519 key
PERSISTENT_SHELL_PASSWORD                      # bootstrap/temporary alternative
PERSISTENT_SHELL_COMMAND_TIMEOUT_SECONDS       # default 60
PERSISTENT_SHELL_MAXIMUM_OUTPUT_BYTES          # default 65536
```

The executable writes MCP protocol messages only to stdout. It does not log commands,
output, passwords, private keys, or host-key confirmation data.

## Verification

Deterministic package checks:

```sh
swift test
swift format lint --recursive Sources Tests Package.swift
git diff --check
```

Real OpenSSH checks are opt-in because they change a single temporary `authorized_keys`
line and then remove it:

```sh
PERSISTENT_SHELL_RUN_LOCALHOST_TEST=1 \
  swift test --filter RealOpenSSHTests/testOptInLocalhostOpenSSH

./Scripts/test-remote-linux-openssh.sh  # macOS package -> ephemeral Linux sshd
./Scripts/test-linux-openssh.sh         # Swift-on-Linux -> Linux localhost sshd
```

The localhost test verifies persistent cwd/environment/function state, multiline heredoc
framing, exit status, bounded output, reset, Ed25519 export, pinning, and cleanup. The Linux
scripts use disposable containers and a fixed test-only password solely to transition to a
fresh per-run Ed25519 key.
