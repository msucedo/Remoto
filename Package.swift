// swift-tools-version: 6.2
import PackageDescription

// Direct dependencies are pinned exactly; bump them on purpose, not by accident.
let package = Package(
    name: "Remoto",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Remoto", targets: ["Remoto"]),
        .executable(name: "remoto-dev", targets: ["remoto-dev"]),
        .library(name: "RemotoCore", targets: ["RemotoCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
    ],
    targets: [
        // Pointer, scroll, keyboard and text injection (CGEvent). No networking.
        .target(name: "RemotoInput"),
        // Server, TLS, pairing, protocol, sessions, deck, actions. No AppKit.
        .target(
            name: "RemotoCore",
            dependencies: [
                "RemotoInput",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        // The menu bar app.
        .executableTarget(name: "Remoto", dependencies: ["RemotoCore"]),
        // Runs the core in a terminal with a logging input sink (development and tests).
        .executableTarget(name: "remoto-dev", dependencies: ["RemotoCore"]),
        .testTarget(name: "RemotoInputTests", dependencies: ["RemotoInput"]),
        .testTarget(name: "RemotoCoreTests", dependencies: ["RemotoCore"]),
    ]
)
