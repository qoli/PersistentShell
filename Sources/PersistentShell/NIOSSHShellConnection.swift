import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

private final class SSHUserAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate,
  @unchecked Sendable
{
  private let username: String
  private let identity: SSHIdentity
  private var offered = false

  init(username: String, identity: SSHIdentity) {
    self.username = username
    self.identity = identity
  }

  func nextAuthenticationType(
    availableMethods: NIOSSHAvailableUserAuthenticationMethods,
    nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
  ) {
    guard !offered else {
      nextChallengePromise.succeed(nil)
      return
    }

    do {
      switch identity.authentication {
      case .ed25519:
        guard availableMethods.contains(.publicKey), let key = try identity.nioPrivateKey() else {
          nextChallengePromise.succeed(nil)
          return
        }
        offered = true
        nextChallengePromise.succeed(
          .init(
            username: username,
            serviceName: "ssh-connection",
            offer: .privateKey(.init(privateKey: key))
          )
        )
      case .password(let password):
        guard availableMethods.contains(.password) else {
          nextChallengePromise.succeed(nil)
          return
        }
        offered = true
        nextChallengePromise.succeed(
          .init(
            username: username,
            serviceName: "ssh-connection",
            offer: .password(.init(password: password))
          )
        )
      }
    } catch {
      nextChallengePromise.fail(error)
    }
  }
}

private final class SSHServerAuthenticationDelegate: NIOSSHClientServerAuthenticationDelegate,
  @unchecked Sendable
{
  private let endpoint: SSHHostEndpoint
  private let validator: any SSHHostKeyValidating

  init(endpoint: SSHHostEndpoint, validator: any SSHHostKeyValidating) {
    self.endpoint = endpoint
    self.validator = validator
  }

  func validateHostKey(
    hostKey: NIOSSHPublicKey,
    validationCompletePromise: EventLoopPromise<Void>
  ) {
    let endpoint = endpoint
    let validator = validator
    let key = SSHHostKey(hostKey)
    Task {
      do {
        try await validator.validate(endpoint: endpoint, key: key)
        validationCompletePromise.succeed(())
      } catch {
        validationCompletePromise.fail(error)
      }
    }
  }
}

private final class ClosingErrorHandler: ChannelInboundHandler {
  typealias InboundIn = Any

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    context.close(promise: nil)
  }
}

final class NIOSSHShellConnection: @unchecked Sendable, ShellConnection {
  private let group: MultiThreadedEventLoopGroup
  private let parentChannel: Channel
  private let shellChannel: Channel
  private let commandHandler: ShellCommandHandler
  private let closeLock = NSLock()
  private var didClose = false

  private init(
    group: MultiThreadedEventLoopGroup,
    parentChannel: Channel,
    shellChannel: Channel,
    commandHandler: ShellCommandHandler
  ) {
    self.group = group
    self.parentChannel = parentChannel
    self.shellChannel = shellChannel
    self.commandHandler = commandHandler
  }

  static func connect(profile: SSHProfile, identity: SSHIdentity) async throws
    -> NIOSSHShellConnection
  {
    try profile.validate()
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    var parent: Channel?

    do {
      let endpoint = SSHHostEndpoint(host: profile.host, port: profile.port)
      let authentication = SSHUserAuthenticationDelegate(
        username: profile.username,
        identity: identity
      )
      let hostKeys = SSHServerAuthenticationDelegate(
        endpoint: endpoint,
        validator: profile.hostKeyValidator
      )
      let timeout = TimeAmount(profile.connectionTimeout)

      let bootstrap = ClientBootstrap(group: group)
        .connectTimeout(timeout)
        .channelInitializer { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandlers(
              NIOSSHHandler(
                role: .client(
                  .init(
                    userAuthDelegate: authentication,
                    serverAuthDelegate: hostKeys
                  )
                ),
                allocator: channel.allocator,
                inboundChildChannelInitializer: nil
              ),
              ClosingErrorHandler()
            )
          }
        }
        .channelOption(
          ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
          value: 1
        )
        .channelOption(
          ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
          value: 1
        )

      let connected = try await bootstrap.connect(host: profile.host, port: profile.port).get()
      parent = connected
      let commandHandler = ShellCommandHandler()
      let child = try await connected.pipeline.handler(type: NIOSSHHandler.self).flatMap {
        sshHandler in
        let childPromise = connected.eventLoop.makePromise(of: Channel.self)
        sshHandler.createChannel(childPromise, channelType: .session) { child, type in
          guard type == .session else {
            return child.eventLoop.makeFailedFuture(
              ShellConnectionError.connectionFailed("unexpected SSH channel type"))
          }
          do {
            try child.pipeline.syncOperations.addHandlers(commandHandler, ClosingErrorHandler())
            return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
          } catch {
            return child.eventLoop.makeFailedFuture(error)
          }
        }
        return childPromise.futureResult
      }.get()

      let shellRequest = child.eventLoop.makePromise(of: Void.self)
      child.pipeline.triggerUserOutboundEvent(
        SSHChannelRequestEvent.ExecRequest(command: "/bin/sh", wantReply: true),
        promise: shellRequest
      )
      try await shellRequest.futureResult.get()

      return NIOSSHShellConnection(
        group: group,
        parentChannel: connected,
        shellChannel: child,
        commandHandler: commandHandler
      )
    } catch let error as PersistentShellError {
      if let parent { try? await parent.close().get() }
      try? await shutdown(group)
      throw error
    } catch {
      if let parent { try? await parent.close().get() }
      try? await shutdown(group)
      throw classifyConnectionError(error)
    }
  }

  func execute(
    command: String,
    nonce: String,
    maximumOutputBytes: Int,
    timeout: Duration
  ) async throws -> RawShellResult {
    let promise = shellChannel.eventLoop.makePromise(of: RawShellResult.self)
    let deadline = TimeAmount(timeout)

    shellChannel.eventLoop.execute { [commandHandler, shellChannel] in
      commandHandler.begin(
        nonce: nonce,
        maximumOutputBytes: maximumOutputBytes,
        timeout: deadline,
        resultPromise: promise,
        channel: shellChannel
      )
    }

    var buffer = shellChannel.allocator.buffer(capacity: command.utf8.count + 256)
    buffer.writeString(Self.frame(command: command, nonce: nonce))
    do {
      try await shellChannel.writeAndFlush(
        SSHChannelData(type: .channel, data: .byteBuffer(buffer))
      ).get()
      return try await promise.futureResult.get()
    } catch let error as ShellConnectionError {
      throw error
    } catch {
      throw ShellConnectionError.disconnected
    }
  }

  func close() async {
    let shouldClose = closeLock.withLock {
      let shouldClose = !didClose
      didClose = true
      return shouldClose
    }
    guard shouldClose else { return }

    try? await parentChannel.close().get()
    try? await shellChannel.close().get()
    try? await Self.shutdown(group)
  }

  private static func frame(command: String, nonce: String) -> String {
    let statusVariable = "__persistent_shell_status_" + nonce
    return command + "\n"
      + statusVariable + "=$?\n"
      + "printf '\\036PERSISTENT_SHELL:" + nonce + ":%s\\037\\n' \"$" + statusVariable + "\"\n"
      + "unset " + statusVariable + "\n"
  }

  private static func shutdown(_ group: MultiThreadedEventLoopGroup) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      group.shutdownGracefully { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private static func classifyConnectionError(_ error: Error) -> PersistentShellError {
    if let error = error as? PersistentShellError { return error }
    if let sshError = error as? NIOSSHError {
      let description = String(describing: sshError)
      if description.localizedCaseInsensitiveContains("authentication") {
        return .authenticationFailed
      }
    }
    return .connectionFailed(String(describing: error))
  }
}

private final class ShellCommandHandler: ChannelInboundHandler, @unchecked Sendable {
  typealias InboundIn = SSHChannelData

  private struct Pending {
    let nonce: String
    var accumulator: ShellCommandAccumulator
    let promise: EventLoopPromise<RawShellResult>
    var timeoutTask: Scheduled<Void>?
  }

  private var pending: Pending?

  func begin(
    nonce: String,
    maximumOutputBytes: Int,
    timeout: TimeAmount,
    resultPromise: EventLoopPromise<RawShellResult>,
    channel: Channel
  ) {
    channel.eventLoop.preconditionInEventLoop()
    guard pending == nil else {
      resultPromise.fail(ShellConnectionError.protocolDesynchronized)
      channel.close(promise: nil)
      return
    }

    var next = Pending(
      nonce: nonce,
      accumulator: ShellCommandAccumulator(nonce: nonce, maximumOutputBytes: maximumOutputBytes),
      promise: resultPromise,
      timeoutTask: nil
    )
    next.timeoutTask = channel.eventLoop.scheduleTask(in: timeout) { [weak self] in
      guard let self, let pending = self.pending, pending.nonce == nonce else { return }
      self.pending = nil
      pending.promise.fail(ShellConnectionError.timedOut)
      channel.close(promise: nil)
    }
    pending = next
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard var pending else { return }
    let channelData = unwrapInboundIn(data)
    guard case .byteBuffer(let buffer) = channelData.data else {
      fail(.protocolDesynchronized, context: context)
      return
    }
    let bytes = Array(buffer.readableBytesView)

    do {
      let result: RawShellResult?
      switch channelData.type {
      case .channel:
        result = try pending.accumulator.receiveStdout(bytes)
      case .stdErr:
        pending.accumulator.receiveStderr(bytes)
        result = nil
      default:
        throw ShellConnectionError.protocolDesynchronized
      }

      if let result {
        pending.timeoutTask?.cancel()
        self.pending = nil
        pending.promise.succeed(result)
      } else {
        self.pending = pending
      }
    } catch let error as ShellConnectionError {
      self.pending = pending
      fail(error, context: context)
    } catch {
      self.pending = pending
      fail(.protocolDesynchronized, context: context)
    }
  }

  func channelInactive(context: ChannelHandlerContext) {
    fail(.disconnected, context: context, close: false)
    context.fireChannelInactive()
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    fail(.disconnected, context: context)
  }

  func handlerRemoved(context: ChannelHandlerContext) {
    fail(.disconnected, context: context, close: false)
  }

  private func fail(
    _ error: ShellConnectionError,
    context: ChannelHandlerContext,
    close: Bool = true
  ) {
    if let pending {
      pending.timeoutTask?.cancel()
      self.pending = nil
      pending.promise.fail(error)
    }
    if close { context.close(promise: nil) }
  }
}

struct ShellCommandAccumulator: Sendable {
  private let markerPrefix: [UInt8]
  private let markerSuffix: [UInt8] = [0x1F, 0x0A]
  private var stdoutScanBuffer: [UInt8] = []
  private var stdout: [UInt8] = []
  private var stderr: [UInt8] = []
  private var remainingOutputBytes: Int
  private(set) var stdoutBytesOmitted = 0
  private(set) var stderrBytesOmitted = 0

  init(nonce: String, maximumOutputBytes: Int) {
    self.markerPrefix = Array(("\u{1E}PERSISTENT_SHELL:" + nonce + ":").utf8)
    self.remainingOutputBytes = maximumOutputBytes
  }

  mutating func receiveStdout(_ bytes: [UInt8]) throws -> RawShellResult? {
    stdoutScanBuffer.append(contentsOf: bytes)

    if let prefixIndex = stdoutScanBuffer.firstRange(of: markerPrefix)?.lowerBound {
      appendStdout(Array(stdoutScanBuffer[..<prefixIndex]))
      stdoutScanBuffer.removeFirst(prefixIndex)
      guard let suffixRange = stdoutScanBuffer.firstRange(of: markerSuffix) else {
        return nil
      }
      let statusStart = markerPrefix.count
      guard statusStart <= suffixRange.lowerBound else {
        throw ShellConnectionError.protocolDesynchronized
      }
      let statusBytes = stdoutScanBuffer[statusStart..<suffixRange.lowerBound]
      guard let statusString = String(bytes: statusBytes, encoding: .utf8),
        let exitCode = Int(statusString)
      else {
        throw ShellConnectionError.protocolDesynchronized
      }
      return RawShellResult(
        stdout: Data(stdout),
        stderr: Data(stderr),
        exitCode: exitCode,
        stdoutBytesOmitted: stdoutBytesOmitted,
        stderrBytesOmitted: stderrBytesOmitted
      )
    }

    let retainedTail = max(0, markerPrefix.count - 1)
    if stdoutScanBuffer.count > retainedTail {
      let flushCount = stdoutScanBuffer.count - retainedTail
      appendStdout(Array(stdoutScanBuffer.prefix(flushCount)))
      stdoutScanBuffer.removeFirst(flushCount)
    }
    return nil
  }

  mutating func receiveStderr(_ bytes: [UInt8]) {
    let accepted = min(remainingOutputBytes, bytes.count)
    stderr.append(contentsOf: bytes.prefix(accepted))
    remainingOutputBytes -= accepted
    stderrBytesOmitted += bytes.count - accepted
  }

  private mutating func appendStdout(_ bytes: [UInt8]) {
    let accepted = min(remainingOutputBytes, bytes.count)
    stdout.append(contentsOf: bytes.prefix(accepted))
    remainingOutputBytes -= accepted
    stdoutBytesOmitted += bytes.count - accepted
  }
}

extension Array where Element: Equatable {
  fileprivate func firstRange(of pattern: [Element]) -> Range<Int>? {
    guard !pattern.isEmpty, pattern.count <= count else { return nil }
    for index in 0...(count - pattern.count) {
      if self[index..<(index + pattern.count)].elementsEqual(pattern) {
        return index..<(index + pattern.count)
      }
    }
    return nil
  }
}
