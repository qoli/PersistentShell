import AnyLanguageModel
import Foundation
import XCTest

@testable import PersistentShell
@testable import PersistentShellTool

final class PersistentShellToolTests: XCTestCase {
  func testSchemaContainsOnlyRequiredCommandAndRejectsAdditionalProperties() throws {
    let tool = PersistentShellTool(shell: makeShell(connection: StatefulConnection()))
    let encoded = try JSONEncoder().encode(tool.parameters)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let definitions = try XCTUnwrap(json["$defs"] as? [String: Any])
    let object = try XCTUnwrap(definitions.values.first as? [String: Any])
    let properties = try XCTUnwrap(object["properties"] as? [String: Any])

    XCTAssertEqual(Set(properties.keys), ["command"])
    XCTAssertEqual(object["required"] as? [String], ["command"])
    XCTAssertEqual(object["additionalProperties"] as? Bool, false)
  }

  func testToolUsesSameShellAcrossLanguageModelSessionRebuild() async throws {
    let connection = StatefulConnection()
    let shell = makeShell(connection: connection)
    let tool = PersistentShellTool(shell: shell)

    let firstCall = try GeneratedContent(json: #"{"command":"cd /workspace"}"#)
    let firstModel = ShellCallingModel(arguments: firstCall, finalAnswer: "changed directory")
    let firstSession = LanguageModelSession(model: firstModel, tools: [tool])
    let firstResponse = try await firstSession.respond(to: "move")
    XCTAssertEqual(firstResponse.content, "changed directory")

    let secondCall = try GeneratedContent(json: #"{"command":"pwd"}"#)
    let secondModel = ShellCallingModel(arguments: secondCall, finalAnswer: "continued")
    let rebuilt = LanguageModelSession(
      model: secondModel,
      tools: [tool],
      transcript: firstSession.transcript
    )
    let secondResponse = try await rebuilt.respond(to: "where")

    XCTAssertEqual(secondResponse.content, "continued")
    XCTAssertTrue(
      secondResponse.transcriptEntries.contains { entry in
        guard case .toolOutput(let output) = entry else { return false }
        return output.segments.contains { segment in
          guard case .text(let text) = segment else { return false }
          return text.content.contains("/workspace")
        }
      }
    )
    let commands = await connection.commands
    XCTAssertEqual(commands, ["cd /workspace", "pwd"])
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

private actor StatefulConnection: ShellConnection {
  private var workingDirectory = "/home/tester"
  private(set) var commands: [String] = []

  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) -> RawShellResult {
    commands.append(command)
    let output: String
    if command.hasPrefix("cd ") {
      workingDirectory = String(command.dropFirst(3))
      output = ""
    } else if command == "pwd" {
      output = workingDirectory + "\n"
    } else {
      output = command
    }
    return RawShellResult(
      stdout: Data(output.utf8), stderr: Data(), exitCode: 0,
      stdoutBytesOmitted: 0, stderrBytesOmitted: 0
    )
  }

  func close() {}
}

private struct ShellCallingModel: LanguageModel {
  typealias UnavailableReason = Never

  let arguments: GeneratedContent
  let finalAnswer: String

  func respond<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
    guard type == String.self,
      let tool = session.tools.first(where: { $0.name == "shell" }) as? PersistentShellTool
    else {
      throw TestFailure.missingShell
    }
    let call = Transcript.ToolCall(id: "shell-call", toolName: "shell", arguments: arguments)
    let parsed = try PersistentShellTool.Arguments(arguments)
    let text = try await tool.call(arguments: parsed)
    let entries: [Transcript.Entry] = [
      .toolCalls(.init([call])),
      .toolOutput(
        .init(id: call.id, toolName: call.toolName, segments: [.text(.init(content: text))])),
    ]
    return LanguageModelSession.Response(
      content: finalAnswer as! Content,
      rawContent: GeneratedContent(finalAnswer),
      transcriptEntries: entries[...]
    )
  }

  func streamResponse<Content>(
    within session: LanguageModelSession,
    to prompt: Prompt,
    generating type: Content.Type,
    includeSchemaInPrompt: Bool,
    options: GenerationOptions
  ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
    LanguageModelSession.ResponseStream(
      content: finalAnswer as! Content,
      rawContent: GeneratedContent(finalAnswer)
    )
  }
}

private enum TestFailure: Error {
  case missingShell
}
