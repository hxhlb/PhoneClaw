// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhoneClawMac",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PhoneClawMac", targets: ["PhoneClawMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .systemLibrary(
            name: "CLiteRtLm",
            path: "Sources/CLiteRtLm",
            pkgConfig: nil,
            providers: nil
        ),
        .executableTarget(
            name: "PhoneClawMac",
            dependencies: ["CLiteRtLm", "Yams"],
            path: "Sources/PhoneClawMac",
            linkerSettings: [
                .unsafeFlags([
                    "-L", ".",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../lib",
                ]),
            ]
        ),
    ]
)
