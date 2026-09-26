import Foundation
import MCP
import XCTest

@testable import PersistentShell
@testable import PersistentShellMCP

final class PersistentShellMCPTests: XCTestCase {
  func testMCPListsAndCallsSameCoreShell() async throws {
    let connection = EchoConnection()
    let shell = makeShell(connection: connection)
    let adapter = PersistentShellMCPAdapter(shell: shell)
    let server = Server(
      name: "test-server",
      version: "1",
      capabilities: .init(tools: .init())
    )
    await adapter.register(on: server)

    let transports = await InMemoryTransport.createConnectedPair()
    try await server.start(transport: transports.server)
    let client = Client(name: "test-client", version: "1")
    _ = try await client.connect(transport: transports.client)

    let (tools, _) = try await client.listTools()
    XCTAssertEqual(tools.map(\.name), ["shell"])
    let schema = try XCTUnwrap(tools.first?.inputSchema.objectValue)
    XCTAssertEqual(schema["additionalProperties"]?.boolValue, false)

    let result = try await client.callTool(
      name: "shell",
      arguments: ["command": .string("printf hello")]
    )
    XCTAssertEqual(result.isError, false)
    guard case .text(let text, _, _) = result.content.first else {
      return XCTFail("expected text result")
    }
    XCTAssertTrue(text.contains("printf hello"))
    XCTAssertTrue(text.contains("[Command finished with exit code 0]"))
    let commands = await connection.commands
    XCTAssertEqual(commands, ["printf hello"])

    await client.disconnect()
    await server.stop()
    await shell.close()
  }

  func testMCPRejectsExtraArgumentsWithoutExecuting() async throws {
    let connection = EchoConnection()
    let adapter = PersistentShellMCPAdapter(shell: makeShell(connection: connection))
    let result = await adapter.call(
      .init(
        name: "shell",
        arguments: ["command": .string("pwd"), "extra": .bool(true)]
      )
    )

    XCTAssertEqual(result.isError, true)
    let commands = await connection.commands
    XCTAssertEqual(commands, [])
  }

  private func makeShell(connection: any ShellConnection) -> PersistentShell {
    let key = try! SSHHostKey(authorizedKey: try! SSHIdentity.generateEd25519().authorizedKey())
    return PersistentShell(
      profile: SSHProfile(
        host: "test.invalid",
        username: "tester",
        hostKeyValidator: PinnedSSHHostKeyValidator(expected: key)
      ),
      identity: SSHIdentity.generateEd25519(),
      connectionFactory: { _, _ in connection }
    )
  }
}

private actor EchoConnection: ShellConnection {
  private(set) var commands: [String] = []

  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) -> RawShellResult {
    commands.append(command)
    return RawShellResult(
      stdout: Data(command.utf8), stderr: Data(), exitCode: 0,
      stdoutBytesOmitted: 0, stderrBytesOmitted: 0
    )
  }

  func close() {}
}
