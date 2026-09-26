import AnyLanguageModel
import PersistentShell

public struct PersistentShellTool: Tool {
  @Generable
  public struct Arguments {
    @Guide(description: "The complete shell command to execute.")
    public let command: String
  }

  public let name = "shell"
  public let description = """
    Execute a command in one persistent SSH-backed /bin/sh. Working directory, exported \
    environment, supported shell functions, activated environments, and background processes \
    persist across calls. Check the final exit-code marker. This shell has no PTY and does not \
    support TUI/full-screen programs. Redirect stdout and stderr for background processes so \
    they do not contaminate later command framing. A cancelled, timed-out, disconnected, or \
    desynchronized command has an unknown outcome; the shell resets and never replays it.
    """

  public let shell: PersistentShell

  public init(shell: PersistentShell) {
    self.shell = shell
  }

  public func call(arguments: Arguments) async throws -> String {
    try await shell.execute(arguments.command).modelOutput
  }
}
