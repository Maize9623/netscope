// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "NetScope",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NetScope", targets: ["NetScope"])],
    targets: [
        .executableTarget(name: "NetScope"),
        .testTarget(name: "NetScopeTests", dependencies: ["NetScope"])
    ]
)
