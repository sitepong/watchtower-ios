// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WatchtowerCore",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "WatchtowerCore", targets: ["WatchtowerCore"]),
    ],
    targets: [
        .target(
            name: "WatchtowerCore",
            path: "Sources/WatchtowerCore"
        ),
    ]
)
