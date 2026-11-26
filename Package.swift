// swift-tools-version: 6.0
import PackageDescription

let settings: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "oton",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "oton", targets: ["OtonApp"]),
        .executable(name: "ot", targets: ["ot"]),
    ],
    targets: [
        .target(name: "OtonCore", swiftSettings: settings),
        .executableTarget(name: "OtonApp", dependencies: ["OtonCore"], swiftSettings: settings),
        .executableTarget(name: "ot", dependencies: ["OtonCore"], swiftSettings: settings),
        .testTarget(name: "OtonCoreTests", dependencies: ["OtonCore"], swiftSettings: settings),
    ]
)
