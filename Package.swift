// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "HungrySpot",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "HungrySpotCore", targets: ["HungrySpotCore"]),
        .executable(name: "HungrySpot", targets: ["HungrySpot"])
    ],
    dependencies: [],
    targets: [
        .target(name: "HungrySpotCore", resources: [.process("Resources")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "HungrySpot", dependencies: ["HungrySpotCore"], resources: [.copy("Resources/Branding.jpg")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "HungrySpotCoreTests", dependencies: ["HungrySpotCore"]),
        .testTarget(name: "HungrySpotAppTests", dependencies: ["HungrySpot"])
    ],
    swiftLanguageVersions: [.v5]
)
