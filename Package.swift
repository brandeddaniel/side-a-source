// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SideA",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SideA", targets: ["SideA"])],
    targets: [
        .target(name: "SideACore"),
        .executableTarget(name: "SideA", dependencies: ["SideACore"],
                          resources: [.process("Resources")]),
        .testTarget(name: "SideACoreTests", dependencies: ["SideACore"])
    ]
)
