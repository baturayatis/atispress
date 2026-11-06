// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AtisPress",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ImpositionCore", targets: ["ImpositionCore"])],
    targets: [
        .target(name: "ImpositionCore"),
        .target(name: "PDFEngine", dependencies: ["ImpositionCore"]),
        .target(name: "AtisPressApp", dependencies: ["ImpositionCore", "PDFEngine"]),
        .testTarget(name: "ImpositionCoreTests", dependencies: ["ImpositionCore"])
    ]
)
