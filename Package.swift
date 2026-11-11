// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tape",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tape", targets: ["Tape"]),
    ],
    targets: [
        // Pure logic with no system dependencies (the mixer, call and mute rules), so it can be unit tested.
        .target(name: "TapeCore", resources: [.process("Resources")]),
        .executableTarget(name: "Tape", dependencies: ["TapeCore"]),
        .testTarget(name: "TapeCoreTests", dependencies: ["TapeCore"]),
    ]
)
