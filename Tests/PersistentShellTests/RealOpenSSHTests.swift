#if os(macOS) || os(Linux)
  import Foundation
  import XCTest

  @testable import PersistentShell

  final class RealOpenSSHTests: XCTestCase {
    func testOptInLocalhostOpenSSH() async throws {
      guard ProcessInfo.processInfo.environment["PERSISTENT_SHELL_RUN_LOCALHOST_TEST"] == "1" else {
        throw XCTSkip(
          "Set PERSISTENT_SHELL_RUN_LOCALHOST_TEST=1 for the localhost OpenSSH acceptance test.")
      }

      let environment = ProcessInfo.processInfo.environment
      let host = environment["PERSISTENT_SHELL_OPENSSH_HOST"] ?? "127.0.0.1"
      let port = Int(environment["PERSISTENT_SHELL_OPENSSH_PORT"] ?? "22") ?? 22
      let username = environment["PERSISTENT_SHELL_OPENSSH_USER"] ?? NSUserName()
      let identity = SSHIdentity.generateEd25519()
      let marker = "persistent-shell-acceptance-" + UUID().uuidString
      let authorizedKey = try identity.authorizedKey(comment: marker)
      let quotedKey = shellQuote(authorizedKey)
      let hostKey = try scannedEd25519HostKey(host: host, port: port)
      let validator = PinnedSSHHostKeyValidator(expected: hostKey)
      let installCommand =
        "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; "
        + "grep -qxF " + quotedKey + " ~/.ssh/authorized_keys || "
        + "printf '%s\\n' " + quotedKey + " >> ~/.ssh/authorized_keys; "
        + "chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys"

      if let password = environment["PERSISTENT_SHELL_OPENSSH_PASSWORD"] {
        let bootstrap = PersistentShell(
          profile: SSHProfile(
            host: host,
            port: port,
            username: username,
            hostKeyValidator: validator
          ),
          identity: try SSHIdentity(password: password)
        )
        let installed = try await bootstrap.execute(installCommand)
        XCTAssertEqual(installed.exitCode, 0)
        await bootstrap.close()
      } else {
        try runSSH(
          host: host,
          port: port,
          username: username,
          command: installCommand
        )
      }

      let cleanupCommand =
        "tmp=~/.ssh/authorized_keys." + marker + "; "
        + "{ grep -vxF " + quotedKey + " ~/.ssh/authorized_keys || true; } > \"$tmp\"; "
        + "chmod 600 \"$tmp\"; mv \"$tmp\" ~/.ssh/authorized_keys"
      addTeardownBlock {
        let cleanup = PersistentShell(
          profile: SSHProfile(
            host: host,
            port: port,
            username: username,
            hostKeyValidator: validator
          ),
          identity: identity
        )
        _ = try? await cleanup.execute(cleanupCommand)
        await cleanup.close()
      }

      let workingDirectory = "/tmp/" + marker
      let profile = SSHProfile(
        host: host,
        port: port,
        username: username,
        hostKeyValidator: validator,
        commandTimeout: .seconds(3),
        maximumOutputBytes: 128
      )
      let shell = PersistentShell(profile: profile, identity: identity)
      addTeardownBlock { await shell.close() }

      let setup = try await shell.execute(
        "mkdir -p " + shellQuote(workingDirectory) + "\n"
          + "cd " + shellQuote(workingDirectory) + "\n"
          + "export PERSISTENT_SHELL_VALUE=retained\n"
          + "persistent_shell_function() { printf function-retained; }"
      )
      XCTAssertEqual(setup.exitCode, 0)

      let retained = try await shell.execute(
        "pwd\nprintf '%s\\n' \"$PERSISTENT_SHELL_VALUE\"\npersistent_shell_function"
      )
      XCTAssertEqual(
        retained.stdout,
        workingDirectory + "\nretained\nfunction-retained"
      )
      XCTAssertEqual(retained.exitCode, 0)

      let multiline = try await shell.execute(
        "value=$(cat <<'PERSISTENT_SHELL_EOF'\nline one\nline two\nPERSISTENT_SHELL_EOF\n)\n"
          + "printf '%s' \"$value\"\nfalse"
      )
      XCTAssertEqual(multiline.stdout, "line one\nline two")
      XCTAssertEqual(multiline.exitCode, 1)

      let large = try await shell.execute("yes x | head -c 1024")
      XCTAssertEqual(large.stdout.utf8.count, 128)
      XCTAssertEqual(large.truncation?.stdoutBytesOmitted, 896)

      await shell.reset()
      let fresh = try await shell.execute("pwd\nprintf '%s' \"${PERSISTENT_SHELL_VALUE-unset}\"")
      XCTAssertNotEqual(fresh.stdout, workingDirectory + "\nretained")
      XCTAssertTrue(fresh.stdout.hasSuffix("\nunset"))

      let failureProfile = SSHProfile(
        host: host,
        port: port,
        username: username,
        hostKeyValidator: validator,
        commandTimeout: .milliseconds(150)
      )
      let failureShell = PersistentShell(profile: failureProfile, identity: identity)
      addTeardownBlock { await failureShell.close() }
      let timeoutSentinel = workingDirectory + "/timeout-sentinel"
      let timeoutStarted = ContinuousClock.now
      do {
        _ = try await failureShell.execute(
          "printf x >> " + shellQuote(timeoutSentinel) + "; sleep 5"
        )
        XCTFail("timeout must fail")
      } catch let error as PersistentShellError {
        XCTAssertEqual(error, .commandTimedOut)
      }
      XCTAssertLessThan(ContinuousClock.now - timeoutStarted, .seconds(1))
      let afterTimeout = try await failureShell.execute("wc -c < " + shellQuote(timeoutSentinel))
      XCTAssertEqual(afterTimeout.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1")

      let cancellationSentinel = workingDirectory + "/cancellation-sentinel"
      let cancellationCommand =
        "printf y >> " + shellQuote(cancellationSentinel) + "; sleep 5"
      let cancelled = Task {
        try await failureShell.execute(cancellationCommand)
      }
      try await Task.sleep(for: .milliseconds(100))
      let cancellationStarted = ContinuousClock.now
      cancelled.cancel()
      do {
        _ = try await cancelled.value
        XCTFail("cancellation must fail")
      } catch let error as PersistentShellError {
        XCTAssertEqual(error, .commandCancelled)
      }
      XCTAssertLessThan(ContinuousClock.now - cancellationStarted, .seconds(1))
      let afterCancellation = try await failureShell.execute(
        "wc -c < " + shellQuote(cancellationSentinel)
      )
      XCTAssertEqual(afterCancellation.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "1")

      do {
        _ = try await failureShell.execute("exit 9")
        XCTFail("disconnect before marker must fail")
      } catch let error as PersistentShellError {
        XCTAssertEqual(error, .disconnected)
      }
      let afterDisconnect = try await failureShell.execute("printf recovered")
      XCTAssertEqual(afterDisconnect.stdout, "recovered")

      _ = try? await shell.execute("rm -rf " + shellQuote(workingDirectory))
    }

    private func scannedEd25519HostKey(host: String, port: Int) throws -> SSHHostKey {
      let output = try run(
        executable: "/usr/bin/ssh-keyscan",
        arguments: ["-T", "3", "-p", String(port), "-t", "ed25519", host]
      )
      guard let line = output.split(separator: "\n").first(where: { !$0.hasPrefix("#") }) else {
        throw AcceptanceError("ssh-keyscan returned no Ed25519 host key")
      }
      let fields = line.split(separator: " ")
      guard fields.count >= 3 else { throw AcceptanceError("invalid ssh-keyscan output") }
      return try SSHHostKey(authorizedKey: String(fields[1]) + " " + String(fields[2]))
    }

    private func runSSH(host: String, port: Int, username: String, command: String) throws {
      _ = try run(
        executable: "/usr/bin/ssh",
        arguments: [
          "-o", "BatchMode=yes",
          "-o", "ConnectTimeout=3",
          "-o", "StrictHostKeyChecking=accept-new",
          "-p", String(port),
          username + "@" + host,
          command,
        ]
      )
    }

    @discardableResult
    private func run(executable: String, arguments: [String]) throws -> String {
      let process = Process()
      let output = Pipe()
      let errors = Pipe()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      process.standardOutput = output
      process.standardError = errors
      try process.run()
      process.waitUntilExit()
      let stdout = output.fileHandleForReading.readDataToEndOfFile()
      let stderr = errors.fileHandleForReading.readDataToEndOfFile()
      guard process.terminationStatus == 0 else {
        throw AcceptanceError(
          "\(executable) failed: " + String(decoding: stderr, as: UTF8.self)
        )
      }
      return String(decoding: stdout, as: UTF8.self)
    }

    private func shellQuote(_ value: String) -> String {
      "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
  }

  private struct AcceptanceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
#endif
