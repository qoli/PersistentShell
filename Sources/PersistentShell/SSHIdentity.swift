import Crypto
import Foundation
import NIOSSH

public struct SSHIdentity: Sendable {
  enum Authentication: Sendable {
    case ed25519(Data)
    case password(String)
  }

  let authentication: Authentication

  public init(ed25519PrivateKeyRawRepresentation: Data) throws {
    _ = try Curve25519.Signing.PrivateKey(rawRepresentation: ed25519PrivateKeyRawRepresentation)
    self.authentication = .ed25519(ed25519PrivateKeyRawRepresentation)
  }

  public init(password: String) throws {
    guard !password.isEmpty else {
      throw PersistentShellError.invalidConfiguration("password must not be empty")
    }
    self.authentication = .password(password)
  }

  public static func generateEd25519() -> SSHIdentity {
    let key = Curve25519.Signing.PrivateKey()
    // A newly generated key always has a valid raw representation.
    return try! SSHIdentity(ed25519PrivateKeyRawRepresentation: key.rawRepresentation)
  }

  public var ed25519PrivateKeyRawRepresentation: Data? {
    guard case .ed25519(let bytes) = authentication else { return nil }
    return bytes
  }

  public func authorizedKey(comment: String? = nil) throws -> String {
    guard case .ed25519(let bytes) = authentication else {
      throw PersistentShellError.invalidConfiguration(
        "a password identity has no public key"
      )
    }
    if let comment, comment.contains("\n") || comment.contains("\r") {
      throw PersistentShellError.invalidConfiguration(
        "authorized_keys comments must not contain newlines"
      )
    }
    let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    let value = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: privateKey).publicKey)
    return comment.map { value + " " + $0 } ?? value
  }

  func nioPrivateKey() throws -> NIOSSHPrivateKey? {
    guard case .ed25519(let bytes) = authentication else { return nil }
    return try NIOSSHPrivateKey(
      ed25519Key: Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    )
  }
}
