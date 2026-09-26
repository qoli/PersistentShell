import Foundation
import MCP
import PersistentShell

public struct PersistentShellMCPAdapter: Sendable {
  public static let toolName = "shell"

  public let shell: PersistentShell

  public init(shell: PersistentShell) {
    self.shell = shell
  }

  public static var toolDefinition: MCP.Tool {
    MCP.Tool(
      name: toolName,
      description: """
        Execute a command in one persistent SSH-backed /bin/sh. State persists across calls. \
        Check the final exit-code marker. No PTY or TUI support. Redirect background output. \
        Interrupted commands have an unknown outcome, reset the shell, and are never replayed.
        """,
      inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "command": .object([
            "type": .string("string"),
            "description": .string("The complete shell command to execute."),
          ])
        ]),
        "required": .array([.string("command")]),
        "additionalProperties": .bool(false),
      ]),
      annotations: .init(
        title: "Persistent shell",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: false,
        openWorldHint: true
      )
    )
  }

  public func register(on server: Server) async {
    await server.withMethodHandler(ListTools.self) { _ in
      .init(tools: [Self.toolDefinition])
    }
    await server.withMethodHandler(CallTool.self) { parameters in
      await call(parameters)
    }
  }

  public func call(_ parameters: CallTool.Parameters) async -> CallTool.Result {
    guard parameters.name == Self.toolName else {
      return errorResult("Unknown tool: \(parameters.name)")
    }
    let arguments = parameters.arguments ?? [:]
    guard arguments.keys.count == 1,
      arguments.keys.first == "command",
      let command = arguments["command"]?.stringValue
    else {
      return errorResult("shell requires exactly one string argument named command")
    }

    do {
      let result = try await shell.execute(command)
      return .init(
        content: [.text(text: result.modelOutput, annotations: nil, _meta: nil)],
        isError: false
      )
    } catch {
      return errorResult(Self.safeDescription(error))
    }
  }

  public func runStdio(
    name: String = "persistent-shell-mcp",
    version: String = "0.1.0"
  ) async throws {
    let server = Server(
      name: name,
      version: version,
      instructions: "One SSH-backed persistent shell. Interrupted commands are never replayed.",
      capabilities: .init(tools: .init())
    )
    await register(on: server)
    let transport = StdioTransport()
    try await server.start(transport: transport)
    await server.waitUntilCompleted()
  }

  private func errorResult(_ message: String) -> CallTool.Result {
    .init(
      content: [.text(text: message, annotations: nil, _meta: nil)],
      isError: true
    )
  }

  private static func safeDescription(_ error: any Error) -> String {
    if let localized = error as? LocalizedError, let description = localized.errorDescription {
      return description
    }
    return String(describing: error)
  }
}
