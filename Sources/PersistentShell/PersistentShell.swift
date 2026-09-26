import Foundation

public actor PersistentShell {
  private let profile: SSHProfile
  private let identity: SSHIdentity
  private let connectionFactory: ShellConnectionFactory

  private var connection: (any ShellConnection)?
  private var connectionGeneration: UInt64 = 0
  private var isClosed = false

  private var commandInProgress = false
  private var commandWaiters: [CheckedContinuation<Void, Never>] = []

  public init(profile: SSHProfile, identity: SSHIdentity) {
    self.profile = profile
    self.identity = identity
    self.connectionFactory = { profile, identity in
      try await NIOSSHShellConnection.connect(profile: profile, identity: identity)
    }
  }

  init(
    profile: SSHProfile,
    identity: SSHIdentity,
    connectionFactory: @escaping ShellConnectionFactory
  ) {
    self.profile = profile
    self.identity = identity
    self.connectionFactory = connectionFactory
  }

  public func execute(_ command: String) async throws -> ShellResult {
    await acquireCommandSlot()
    defer { releaseCommandSlot() }

    try Task.checkCancellation()
    guard !isClosed else { throw PersistentShellError.closed }
    try profile.validate()

    let currentConnection: any ShellConnection
    if let connection {
      currentConnection = connection
    } else {
      let creationGeneration = connectionGeneration
      do {
        currentConnection = try await connectionFactory(profile, identity)
      } catch let error as PersistentShellError {
        throw error
      } catch let error as ShellConnectionError {
        throw map(error)
      } catch {
        throw PersistentShellError.connectionFailed(String(describing: error))
      }
      if Task.isCancelled {
        await currentConnection.close()
        throw CancellationError()
      }
      guard creationGeneration == connectionGeneration else {
        await currentConnection.close()
        throw PersistentShellError.disconnected
      }
      guard !isClosed else {
        await currentConnection.close()
        throw PersistentShellError.closed
      }
      connection = currentConnection
      connectionGeneration &+= 1
    }

    let generation = connectionGeneration
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    do {
      let raw = try await withTaskCancellationHandler {
        try await currentConnection.execute(
          command: command,
          nonce: nonce,
          maximumOutputBytes: profile.maximumOutputBytes,
          timeout: profile.commandTimeout
        )
      } onCancel: {
        Task { await self.interrupt(generation: generation) }
      }
      try Task.checkCancellation()
      guard generation == connectionGeneration, !isClosed else {
        throw PersistentShellError.disconnected
      }
      return raw.publicResult
    } catch is CancellationError {
      await invalidate(generation: generation)
      throw PersistentShellError.commandCancelled
    } catch let error as PersistentShellError {
      if error.outcomeUnknown { await invalidate(generation: generation) }
      throw error
    } catch let error as ShellConnectionError {
      await invalidate(generation: generation)
      if Task.isCancelled { throw PersistentShellError.commandCancelled }
      throw map(error)
    } catch {
      await invalidate(generation: generation)
      if Task.isCancelled { throw PersistentShellError.commandCancelled }
      throw PersistentShellError.disconnected
    }
  }

  /// Invalidates the current SSH connection and shell. The next execute lazily creates a fresh one.
  public func reset() async {
    let old = connection
    connection = nil
    connectionGeneration &+= 1
    await old?.close()
  }

  /// Permanently closes this actor. A closed shell cannot be reused.
  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    let old = connection
    connection = nil
    connectionGeneration &+= 1
    await old?.close()
  }

  private func acquireCommandSlot() async {
    if !commandInProgress {
      commandInProgress = true
      return
    }
    await withCheckedContinuation { continuation in
      commandWaiters.append(continuation)
    }
  }

  private func releaseCommandSlot() {
    if commandWaiters.isEmpty {
      commandInProgress = false
    } else {
      commandWaiters.removeFirst().resume()
    }
  }

  private func interrupt(generation: UInt64) async {
    guard generation == connectionGeneration else { return }
    await invalidate(generation: generation)
  }

  private func invalidate(generation: UInt64) async {
    guard generation == connectionGeneration else { return }
    let old = connection
    connection = nil
    connectionGeneration &+= 1
    await old?.close()
  }

  private func map(_ error: ShellConnectionError) -> PersistentShellError {
    switch error {
    case .timedOut: .commandTimedOut
    case .disconnected: .disconnected
    case .protocolDesynchronized: .protocolDesynchronized
    case .authenticationFailed: .authenticationFailed
    case .connectionFailed(let message): .connectionFailed(message)
    }
  }
}
