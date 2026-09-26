import Foundation

public struct SSHProfile: Sendable {
  public let host: String
  public let port: Int
  public let username: String
  public let hostKeyValidator: any SSHHostKeyValidating
  public let connectionTimeout: Duration
  public let commandTimeout: Duration
  public let maximumOutputBytes: Int

  public init(
    host: String,
    port: Int = 22,
    username: String,
    hostKeyValidator: any SSHHostKeyValidating,
    connectionTimeout: Duration = .seconds(15),
    commandTimeout: Duration = .seconds(60),
    maximumOutputBytes: Int = 65_536
  ) {
    self.host = host
    self.port = port
    self.username = username
    self.hostKeyValidator = hostKeyValidator
    self.connectionTimeout = connectionTimeout
    self.commandTimeout = commandTimeout
    self.maximumOutputBytes = maximumOutputBytes
  }

  func validate() throws {
    guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PersistentShellError.invalidConfiguration("host must not be empty")
    }
    guard (1...65_535).contains(port) else {
      throw PersistentShellError.invalidConfiguration("port must be between 1 and 65535")
    }
    guard !username.isEmpty else {
      throw PersistentShellError.invalidConfiguration("username must not be empty")
    }
    guard connectionTimeout > .zero else {
      throw PersistentShellError.invalidConfiguration("connectionTimeout must be positive")
    }
    guard commandTimeout > .zero else {
      throw PersistentShellError.invalidConfiguration("commandTimeout must be positive")
    }
    guard maximumOutputBytes >= 0 else {
      throw PersistentShellError.invalidConfiguration("maximumOutputBytes must be nonnegative")
    }
  }
}
