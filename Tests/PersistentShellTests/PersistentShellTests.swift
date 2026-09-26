import Foundation
import XCTest

@testable import PersistentShell

final class PersistentShellTests: XCTestCase {
  func testAccumulatorParsesSplitMarkerAndKeepsStreamsSeparate() throws {
    let nonce = "abc123"
    var accumulator = ShellCommandAccumulator(nonce: nonce, maximumOutputBytes: 1_024)
    accumulator.receiveStderr(Array("warning\n".utf8))

    XCTAssertNil(try accumulator.receiveStdout(Array("hello".utf8)))
    XCTAssertNil(
      try accumulator.receiveStdout(
        Array(" world\u{1E}PERSISTENT_SHELL:abc".utf8)
      )
    )
    let result = try XCTUnwrap(
      accumulator.receiveStdout(Array("123:7\u{1F}\nignored".utf8))
    )

    XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "hello world")
    XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "warning\n")
    XCTAssertEqual(result.exitCode, 7)
    XCTAssertEqual(result.stdoutBytesOmitted, 0)
    XCTAssertEqual(result.stderrBytesOmitted, 0)
  }

  func testAccumulatorCapsCombinedOutputAndReportsOmittedBytes() throws {
    let nonce = "limit"
    var accumulator = ShellCommandAccumulator(nonce: nonce, maximumOutputBytes: 5)
    accumulator.receiveStderr(Array("123".utf8))
    let result = try XCTUnwrap(
      accumulator.receiveStdout(
        Array("abcdef\u{1E}PERSISTENT_SHELL:limit:0\u{1F}\n".utf8)
      )
    )

    XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "123")
    XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ab")
    XCTAssertEqual(result.stdoutBytesOmitted, 4)
    XCTAssertEqual(result.stderrBytesOmitted, 0)
  }

  func testIdentityExportsOpenSSHAuthorizedKeyAndRoundTrips() throws {
    let identity = SSHIdentity.generateEd25519()
    let exported = try identity.authorizedKey(comment: "persistent-shell-test")
    let parsed = try SSHHostKey(authorizedKey: exported)

    XCTAssertTrue(exported.hasPrefix("ssh-ed25519 "))
    XCTAssertTrue(exported.hasSuffix(" persistent-shell-test"))
    XCTAssertTrue(parsed.fingerprintSHA256.hasPrefix("SHA256:"))
    XCTAssertNotNil(identity.ed25519PrivateKeyRawRepresentation)
  }

  func testTOFUPinsFirstConfirmedKeyAndRejectsChange() async throws {
    let first = try SSHHostKey(
      authorizedKey: try SSHIdentity.generateEd25519().authorizedKey()
    )
    let changed = try SSHHostKey(
      authorizedKey: try SSHIdentity.generateEd25519().authorizedKey()
    )
    let endpoint = SSHHostEndpoint(host: "example.test", port: 22)
    let store = MemoryPinStore()
    let confirmations = Counter()
    let validator = TrustOnFirstUseSSHHostKeyValidator(store: store) { _, _ in
      await confirmations.increment()
      return true
    }

    try await validator.validate(endpoint: endpoint, key: first)
    try await validator.validate(endpoint: endpoint, key: first)
    let confirmationCount = await confirmations.value
    XCTAssertEqual(confirmationCount, 1)

    do {
      try await validator.validate(endpoint: endpoint, key: changed)
      XCTFail("changed host key must fail")
    } catch let error as PersistentShellError {
      guard case .hostKeyRejected = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }

  func testCommandsAreSerialized() async throws {
    let tracker = ConcurrencyTracker()
    let connection = ConcurrentProbeConnection(tracker: tracker)
    let shell = makeShell { _, _ in connection }

    async let first = shell.execute("first")
    async let second = shell.execute("second")
    _ = try await (first, second)

    let maximumActive = await tracker.maximumActive
    let commands = await tracker.commands
    XCTAssertEqual(maximumActive, 1)
    XCTAssertEqual(commands.count, 2)
    XCTAssertEqual(Set(commands), ["first", "second"])
  }

  func testTimeoutInvalidatesConnectionAndNeverReplaysCommand() async throws {
    let state = SequencedFactoryState(
      connections: [
        ScriptedConnection(outcomes: [.failure(.timedOut)]),
        ScriptedConnection(outcomes: [.success("fresh")]),
      ]
    )
    let shell = makeShell { _, _ in try await state.next() }

    do {
      _ = try await shell.execute("side-effect")
      XCTFail("timeout must fail")
    } catch let error as PersistentShellError {
      XCTAssertEqual(error, .commandTimedOut)
      XCTAssertTrue(error.outcomeUnknown)
    }

    let next = try await shell.execute("pwd")
    XCTAssertEqual(next.stdout, "fresh")
    let commands = await state.recordedCommands()
    XCTAssertEqual(commands, [["side-effect"], ["pwd"]])
  }

  func testCancellationResetsAndNextCallUsesFreshConnection() async throws {
    let blocking = BlockingConnection()
    let fresh = ScriptedConnection(outcomes: [.success("fresh")])
    let state = SequencedFactoryState(connections: [blocking, fresh])
    let shell = makeShell { _, _ in try await state.next() }

    let task = Task { try await shell.execute("long-running") }
    await blocking.waitUntilStarted()
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("cancelled command must fail")
    } catch let error as PersistentShellError {
      XCTAssertEqual(error, .commandCancelled)
      XCTAssertTrue(error.outcomeUnknown)
    }

    let result = try await shell.execute("after")
    XCTAssertEqual(result.stdout, "fresh")
    let closeCount = await blocking.closeCount
    XCTAssertEqual(closeCount, 1)
  }

  private func makeShell(
    factory: @escaping ShellConnectionFactory
  ) -> PersistentShell {
    let hostKey = try! SSHHostKey(
      authorizedKey: try! SSHIdentity.generateEd25519().authorizedKey()
    )
    return PersistentShell(
      profile: SSHProfile(
        host: "test.invalid",
        username: "tester",
        hostKeyValidator: PinnedSSHHostKeyValidator(expected: hostKey)
      ),
      identity: SSHIdentity.generateEd25519(),
      connectionFactory: factory
    )
  }
}

private actor MemoryPinStore: SSHHostKeyPinningStore {
  private var keys: [SSHHostEndpoint: SSHHostKey] = [:]

  func pinnedKey(for endpoint: SSHHostEndpoint) -> SSHHostKey? { keys[endpoint] }

  func savePinnedKey(_ key: SSHHostKey, for endpoint: SSHHostEndpoint) {
    keys[endpoint] = key
  }

  func resetPinnedKey(for endpoint: SSHHostEndpoint) {
    keys.removeValue(forKey: endpoint)
  }
}

private actor Counter {
  private(set) var value = 0
  func increment() { value += 1 }
}

private actor ConcurrencyTracker {
  private(set) var active = 0
  private(set) var maximumActive = 0
  private(set) var commands: [String] = []

  func begin(_ command: String) {
    active += 1
    maximumActive = max(maximumActive, active)
    commands.append(command)
  }

  func end() { active -= 1 }
}

private struct ConcurrentProbeConnection: ShellConnection {
  let tracker: ConcurrencyTracker

  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) async throws -> RawShellResult {
    await tracker.begin(command)
    try await Task.sleep(for: .milliseconds(25))
    await tracker.end()
    return RawShellResult(
      stdout: Data(command.utf8), stderr: Data(), exitCode: 0,
      stdoutBytesOmitted: 0, stderrBytesOmitted: 0
    )
  }

  func close() async {}
}

private actor ScriptedConnection: ShellConnection {
  enum Outcome: Sendable {
    case success(String)
    case failure(ShellConnectionError)
  }

  private var outcomes: [Outcome]
  private(set) var commands: [String] = []
  private(set) var closeCount = 0

  init(outcomes: [Outcome]) {
    self.outcomes = outcomes
  }

  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) throws -> RawShellResult {
    commands.append(command)
    guard !outcomes.isEmpty else { throw ShellConnectionError.disconnected }
    switch outcomes.removeFirst() {
    case .success(let output):
      return RawShellResult(
        stdout: Data(output.utf8), stderr: Data(), exitCode: 0,
        stdoutBytesOmitted: 0, stderrBytesOmitted: 0
      )
    case .failure(let error):
      throw error
    }
  }

  func close() { closeCount += 1 }
}

private actor BlockingConnection: ShellConnection {
  private var continuation: CheckedContinuation<RawShellResult, any Error>?
  private var startedContinuations: [CheckedContinuation<Void, Never>] = []
  private(set) var closeCount = 0
  private var started = false

  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) async throws -> RawShellResult {
    started = true
    for continuation in startedContinuations {
      continuation.resume()
    }
    startedContinuations.removeAll()
    return try await withCheckedThrowingContinuation { continuation = $0 }
  }

  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { startedContinuations.append($0) }
  }

  func close() {
    closeCount += 1
    continuation?.resume(throwing: ShellConnectionError.disconnected)
    continuation = nil
  }
}

private actor SequencedFactoryState {
  private var connections: [any ShellConnection]
  private var returned: [any ShellConnection] = []

  init(connections: [any ShellConnection]) {
    self.connections = connections
  }

  func next() throws -> any ShellConnection {
    guard !connections.isEmpty else { throw ShellConnectionError.connectionFailed("no fixture") }
    let connection = connections.removeFirst()
    returned.append(connection)
    return connection
  }

  func recordedCommands() async -> [[String]] {
    var result: [[String]] = []
    for connection in returned {
      if let scripted = connection as? ScriptedConnection {
        result.append(await scripted.commands)
      }
    }
    return result
  }
}
