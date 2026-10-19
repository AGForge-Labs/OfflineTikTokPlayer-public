// swift-tools-version: 6.0
import PackageDescription
import Foundation

let package = Package(
    name: "NativeCloudAdapterChecks",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: ProcessInfo.processInfo.environment["PLAYER_CORE_PATH"]!)],
    targets: [
        .target(name: "CloudAdapter", dependencies: [.product(name: "PlayerCore", package: "PlayerCore")]),
        .testTarget(name: "CloudAdapterTests", dependencies: ["CloudAdapter", .product(name: "PlayerCore", package: "PlayerCore")])
    ],
    swiftLanguageModes: [.v5]
)
