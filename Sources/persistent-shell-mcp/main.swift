import Foundation
import PersistentShell
import PersistentShellMCP

@main
enum PersistentShellMCPCommand {
  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    let host = try required("PERSISTENT_SHELL_HOST", in: environment)
    let username = try required("PERSISTENT_SHELL_USER", in: environment)
    let pinnedHostKey = try SSHHostKey(
      authorizedKey: required("PERSISTENT_SHELL_HOST_KEY", in: environment)
    )
    let port = try integer("PERSISTENT_SHELL_PORT", in: environment, default: 22)
    let timeoutSeconds = try integer(
      "PERSISTENT_SHELL_COMMAND_TIMEOUT_SECONDS",
      in: environment,
      default: 60
    )
    let maximumOutputBytes = try integer(
      "PERSISTENT_SHELL_MAXIMUM_OUTPUT_BYTES",
      in: environment,
      default: 65_536
    )

    let identity: SSHIdentity
    if let encoded = environment["PERSISTENT_SHELL_PRIVATE_KEY_BASE64"] {
      guard let data = Data(base64Encoded: encoded) else {
        throw ConfigurationError("PERSISTENT_SHELL_PRIVATE_KEY_BASE64 must be valid base64.")
      }
      identity = try SSHIdentity(ed25519PrivateKeyRawRepresentation: data)
    } else if let password = environment["PERSISTENT_SHELL_PASSWORD"] {
      identity = try SSHIdentity(password: password)
    } else {
      throw ConfigurationError(
        "Set PERSISTENT_SHELL_PRIVATE_KEY_BASE64 or PERSISTENT_SHELL_PASSWORD."
      )
    }

    let profile = SSHProfile(
      host: host,
      port: port,
      username: username,
      hostKeyValidator: PinnedSSHHostKeyValidator(expected: pinnedHostKey),
      commandTimeout: .seconds(timeoutSeconds),
      maximumOutputBytes: maximumOutputBytes
    )
    let shell = PersistentShell(profile: profile, identity: identity)
    do {
      try await PersistentShellMCPAdapter(shell: shell).runStdio()
      await shell.close()
    } catch {
      await shell.close()
      throw error
    }
  }

  private static func required(_ name: String, in environment: [String: String]) throws -> String {
    guard let value = environment[name], !value.isEmpty else {
      throw ConfigurationError("Missing required environment variable \(name).")
    }
    return value
  }

  private static func integer(
    _ name: String,
    in environment: [String: String],
    default defaultValue: Int
  ) throws -> Int {
    guard let raw = environment[name] else { return defaultValue }
    guard let value = Int(raw) else {
      throw ConfigurationError("\(name) must be an integer.")
    }
    return value
  }
}

private struct ConfigurationError: LocalizedError {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var errorDescription: String? { message }
}
