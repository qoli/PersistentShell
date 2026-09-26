import Foundation

public struct ShellOutputTruncation: Sendable, Equatable, Codable {
  public let stdoutBytesOmitted: Int
  public let stderrBytesOmitted: Int

  public init(stdoutBytesOmitted: Int, stderrBytesOmitted: Int) {
    self.stdoutBytesOmitted = stdoutBytesOmitted
    self.stderrBytesOmitted = stderrBytesOmitted
  }

  public var totalBytesOmitted: Int { stdoutBytesOmitted + stderrBytesOmitted }
}

public struct ShellResult: Sendable, Equatable, Codable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int
  public let truncation: ShellOutputTruncation?

  public init(
    stdout: String,
    stderr: String,
    exitCode: Int,
    truncation: ShellOutputTruncation? = nil
  ) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
    self.truncation = truncation
  }

  /// A model-facing rendering that keeps stderr distinct and always exposes the exit status.
  public var modelOutput: String {
    var sections: [String] = []
    if !stdout.isEmpty { sections.append(stdout) }
    if !stderr.isEmpty { sections.append("[stderr]\n\(stderr)") }
    if let truncation, truncation.totalBytesOmitted > 0 {
      sections.append(
        "[Output truncated: \(truncation.stdoutBytesOmitted) stdout bytes and "
          + "\(truncation.stderrBytesOmitted) stderr bytes omitted]"
      )
    }
    sections.append("[Command finished with exit code \(exitCode)]")
    return sections.joined(separator: sections.count > 1 ? "\n" : "")
  }
}
