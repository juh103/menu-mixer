// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MenuMixer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "MixerDSP", publicHeadersPath: "include"),
        .executableTarget(name: "MenuMixer", dependencies: ["MixerDSP"])
    ]
)
