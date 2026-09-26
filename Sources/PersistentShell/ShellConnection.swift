import Foundation

struct RawShellResult: Sendable, Equatable {
  let stdout: Data
  let stderr: Data
  let exitCode: Int
  let stdoutBytesOmitted: Int
  let stderrBytesOmitted: Int

  var publicResult: ShellResult {
    let omitted = stdoutBytesOmitted + stderrBytesOmitted
    return ShellResult(
      stdout: String(decoding: stdout, as: UTF8.self),
      stderr: String(decoding: stderr, as: UTF8.self),
      exitCode: exitCode,
      truncation: omitted == 0
        ? nil
        : ShellOutputTruncation(
          stdoutBytesOmitted: stdoutBytesOmitted,
          stderrBytesOmitted: stderrBytesOmitted
        )
    )
  }
}

enum ShellConnectionError: Error, Sendable, Equatable {
  case timedOut
  case disconnected
  case protocolDesynchronized
  case authenticationFailed
  case connectionFailed(String)
}

protocol ShellConnection: Sendable {
  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) async throws -> RawShellResult
  func close() async
}

typealias ShellConnectionFactory =
  @Sendable (SSHProfile, SSHIdentity) async throws -> any ShellConnection
