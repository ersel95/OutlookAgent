// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OutlookAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OutlookAgent", targets: ["OutlookAgent"])
    ],
    targets: [
        .executableTarget(
            name: "OutlookAgent",
            path: "Sources/OutlookAgent",
            resources: [.process("Scripts")]
        )
    ]
)
