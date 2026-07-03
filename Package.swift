// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Zoomy",
    platforms: [.iOS(.v15)],
    products: [.library(name: "Zoomy", targets: ["Zoomy"])],
    targets: [
        .target(name: "Zoomy"),
        .testTarget(name: "ZoomyTests", dependencies: ["Zoomy"])
    ]
)
