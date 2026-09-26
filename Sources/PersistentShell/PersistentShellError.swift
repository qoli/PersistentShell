import Foundation

public enum PersistentShellError: Error, Sendable, Equatable {
  case invalidConfiguration(String)
  case hostKeyRejected(String)
  case authenticationFailed
  case connectionFailed(String)
  case commandTimedOut
  case commandCancelled
  case disconnected
  case protocolDesynchronized
  case closed

  public var outcomeUnknown: Bool {
    switch self {
    case .commandTimedOut, .commandCancelled, .disconnected, .protocolDesynchronized:
      true
    case .invalidConfiguration, .hostKeyRejected, .authenticationFailed,
      .connectionFailed, .closed:
      false
    }
  }
}

extension PersistentShellError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message):
      "Invalid SSH configuration: \(message)"
    case .hostKeyRejected(let message):
      "SSH host key rejected: \(message)"
    case .authenticationFailed:
      "SSH authentication failed."
    case .connectionFailed(let message):
      "SSH connection failed: \(message)"
    case .commandTimedOut:
      "Shell command timed out; its outcome is unknown and the shell was reset."
    case .commandCancelled:
      "Shell command was cancelled; its outcome is unknown and the shell was reset."
    case .disconnected:
      "SSH disconnected before command completion; its outcome is unknown and the shell was reset."
    case .protocolDesynchronized:
      "Shell completion framing was lost; the command outcome is unknown and the shell was reset."
    case .closed:
      "Persistent shell is closed."
    }
  }
}
