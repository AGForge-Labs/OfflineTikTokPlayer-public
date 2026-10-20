// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PlayerCore",
    platforms: [.iOS("26.0"), .macOS(.v15)],
    products: [.library(name: "PlayerCore", targets: ["PlayerCore"])],
    targets: [
        .target(name: "PlayerCore"),
        .testTarget(name: "PlayerCoreTests", dependencies: ["PlayerCore"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v5]
)
