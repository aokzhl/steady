// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Steady",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SteadyCore", targets: ["SteadyCore"]),
        .executable(name: "Steady", targets: ["SteadyApp"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "SteadyCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "SteadyApp", dependencies: ["SteadyCore"]),
        .testTarget(name: "SteadyCoreTests", dependencies: ["SteadyCore"], exclude: ["Fixtures"]),
    ]
)
