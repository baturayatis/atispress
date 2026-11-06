// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AtisPress",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImpositionCore", targets: ["ImpositionCore"]),
        .executable(name: "AtisPressApp", targets: ["AtisPressApp"])
    ],
    targets: [
        .target(name: "ImpositionCore"),
        .target(name: "PDFEngine", dependencies: ["ImpositionCore"]),
        .executableTarget(name: "AtisPressApp", dependencies: ["ImpositionCore", "PDFEngine"]),
        .testTarget(name: "ImpositionCoreTests", dependencies: ["ImpositionCore"]),
        .testTarget(name: "PDFEngineTests", dependencies: ["PDFEngine"]),
        .testTarget(name: "AtisPressAppTests", dependencies: ["AtisPressApp"])
    ]
)
