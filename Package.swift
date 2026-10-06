// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "PersistentShell",
  platforms: [
    .macOS(.v14),
    .iOS(.v17),
  ],
  products: [
    .library(name: "PersistentShell", targets: ["PersistentShell"]),
    .library(name: "PersistentShellTool", targets: ["PersistentShellTool"]),
    .library(name: "PersistentShellMCP", targets: ["PersistentShellMCP"]),
    .executable(name: "persistent-shell-mcp", targets: ["persistent-shell-mcp"]),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.15.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", "1.0.0"..<"5.0.0"),
    // Preserve the currently verified NIO/JSONSchema dependency lines during the AML update.
    .package(url: "https://github.com/apple/swift-collections.git", "1.2.1"..<"1.3.0"),
    .package(url: "https://github.com/apple/swift-log.git", "1.10.1"..<"1.11.0"),
    .package(url: "https://github.com/qoli/AnyLanguageModel.git", branch: "main"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
  ],
  targets: [
    .target(
      name: "PersistentShell",
      dependencies: [
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
        .product(name: "Crypto", package: "swift-crypto"),
      ]
    ),
    .target(
      name: "PersistentShellTool",
      dependencies: [
        "PersistentShell",
        .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
      ]
    ),
    .target(
      name: "PersistentShellMCP",
      dependencies: [
        "PersistentShell",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
    .executableTarget(
      name: "persistent-shell-mcp",
      dependencies: ["PersistentShell", "PersistentShellMCP"]
    ),
    .testTarget(
      name: "PersistentShellTests",
      dependencies: [
        "PersistentShell",
        // Keep the pinned Logging/OrderedCollections products covered in package tests.
        .product(name: "Logging", package: "swift-log"),
        .product(name: "OrderedCollections", package: "swift-collections"),
      ]
    ),
    .testTarget(
      name: "PersistentShellToolTests",
      dependencies: [
        "PersistentShell",
        "PersistentShellTool",
        .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
      ]
    ),
    .testTarget(
      name: "PersistentShellMCPTests",
      dependencies: [
        "PersistentShell",
        "PersistentShellMCP",
        .product(name: "MCP", package: "swift-sdk"),
      ]
    ),
  ]
)
