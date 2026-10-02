// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ShadeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShadeCore", targets: ["ShadeCore"]),
        .library(name: "ShadeFeatures", targets: ["ShadeFeatures"]),
    ],
    targets: [
        .target(name: "ShadeCore"),
        .target(name: "ShadeFeatures", dependencies: ["ShadeCore"]),
        .testTarget(
            name: "ShadeCoreTests",
            dependencies: ["ShadeCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "ShadeFeaturesTests", dependencies: ["ShadeFeatures", "ShadeCore"]),
    ]
)
