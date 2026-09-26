import Crypto
import Foundation
import NIOSSH

public struct SSHHostEndpoint: Sendable, Hashable, Codable {
  public let host: String
  public let port: Int

  public init(host: String, port: Int) {
    self.host = host
    self.port = port
  }
}

public struct SSHHostKey: Sendable, Hashable, Codable {
  public let authorizedKey: String
  public let fingerprintSHA256: String

  public init(authorizedKey: String) throws {
    let parsed = try NIOSSHPublicKey(openSSHPublicKey: authorizedKey)
    self.init(parsed)
  }

  init(_ key: NIOSSHPublicKey) {
    let authorizedKey = String(openSSHPublicKey: key)
    self.authorizedKey = authorizedKey
    let encoded = authorizedKey.split(separator: " ", maxSplits: 2)[1]
    let wireBytes = Data(base64Encoded: String(encoded)) ?? Data()
    let digest = SHA256.hash(data: wireBytes)
    self.fingerprintSHA256 =
      "SHA256:"
      + Data(digest).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
  }
}

public protocol SSHHostKeyValidating: Sendable {
  func validate(endpoint: SSHHostEndpoint, key: SSHHostKey) async throws
}

public struct PinnedSSHHostKeyValidator: SSHHostKeyValidating {
  public let expected: SSHHostKey

  public init(expected: SSHHostKey) {
    self.expected = expected
  }

  public func validate(endpoint: SSHHostEndpoint, key: SSHHostKey) async throws {
    guard key == expected else {
      throw PersistentShellError.hostKeyRejected(
        "the key for \(endpoint.host):\(endpoint.port) changed (received \(key.fingerprintSHA256))"
      )
    }
  }
}

public protocol SSHHostKeyPinningStore: Sendable {
  func pinnedKey(for endpoint: SSHHostEndpoint) async throws -> SSHHostKey?
  func savePinnedKey(_ key: SSHHostKey, for endpoint: SSHHostEndpoint) async throws
  func resetPinnedKey(for endpoint: SSHHostEndpoint) async throws
}

public struct TrustOnFirstUseSSHHostKeyValidator: SSHHostKeyValidating {
  public typealias Confirmation = @Sendable (SSHHostEndpoint, SSHHostKey) async throws -> Bool

  private let store: any SSHHostKeyPinningStore
  private let confirmation: Confirmation

  public init(store: any SSHHostKeyPinningStore, confirmation: @escaping Confirmation) {
    self.store = store
    self.confirmation = confirmation
  }

  public func validate(endpoint: SSHHostEndpoint, key: SSHHostKey) async throws {
    if let pinned = try await store.pinnedKey(for: endpoint) {
      guard pinned == key else {
        throw PersistentShellError.hostKeyRejected(
          "the pinned key for \(endpoint.host):\(endpoint.port) changed from "
            + "\(pinned.fingerprintSHA256) to \(key.fingerprintSHA256)"
        )
      }
      return
    }

    guard try await confirmation(endpoint, key) else {
      throw PersistentShellError.hostKeyRejected(
        "the first key for \(endpoint.host):\(endpoint.port) was not confirmed"
      )
    }
    try await store.savePinnedKey(key, for: endpoint)
  }
}
