// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RoomwaveCore",
    platforms: [.iOS("27.0"), .macOS("15.0")],
    products: [
        .library(name: "RoomwaveCore", targets: ["RoomwaveCore"]),
        .library(name: "RoomwaveArcade", targets: ["RoomwaveArcade"])
    ],
    targets: [
        .target(name: "RoomwaveCore"),
        .testTarget(name: "RoomwaveCoreTests", dependencies: ["RoomwaveCore"]),
        .target(name: "RoomwaveArcade"),
        .testTarget(name: "RoomwaveArcadeTests", dependencies: ["RoomwaveArcade"])
    ]
)
