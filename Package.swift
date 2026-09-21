// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacbookRemote",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        .library(name: "RemoteProtocol", targets: ["RemoteProtocol"]),
        .library(name: "RemoteClientCore", targets: ["RemoteClientCore"]),
        .library(name: "RemoteServerCore", targets: ["RemoteServerCore"]),
        .executable(name: "remotectl", targets: ["remotectl"]),
    ],
    targets: [
        .target(name: "RemoteProtocol"),
        .target(name: "RemoteClientCore", dependencies: ["RemoteProtocol"]),
        .target(name: "RemoteServerCore", dependencies: ["RemoteProtocol"]),
        .executableTarget(
            name: "remotectl",
            dependencies: ["RemoteProtocol", "RemoteClientCore", "RemoteServerCore"]
        ),
        .testTarget(name: "RemoteProtocolTests", dependencies: ["RemoteProtocol"]),
    ]
)
