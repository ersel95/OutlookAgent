// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OutlookAgent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OutlookAgent", targets: ["OutlookAgent"])
    ],
    dependencies: [
        // Sparkle auto-update. Pulled via SPM; .framework is embedded + signed
        // inside-out by build.sh (dev) / scripts/release.sh (CI).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "OutlookAgent",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/OutlookAgent",
            resources: [.process("Scripts")],
            linkerSettings: [
                // SPM default rpath'i sadece @executable_path; Sparkle.framework
                // Contents/Frameworks/'te oldugu icin @executable_path/../Frameworks
                // gerekiyor (yoksa dyld bulamaz → SIGABRT at launch).
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
