// swift-tools-version: 6.0
import PackageDescription

// PhoneClawEngine
//
// Swift Package for running LiteRT-LM language models on iOS GPU (Metal).
//
// The compiled xcframework (with LiteRT-LM engine + Metal accelerator + a
// community-written native Metal TopK sampler + Gemma model constraint
// provider) is hosted as a GitHub Release asset on this repo. Swift Package
// Manager auto-downloads the artifact at dependency-resolve time; no manual
// binary management.
//
// Binary source truth:
//   https://github.com/kellyvv/PhoneClawEngine/releases
//
let package = Package(
    name: "PhoneClawEngine",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(name: "PhoneClawEngine", targets: ["PhoneClawEngine"]),
    ],
    targets: [
        // Binary xcframework: LiteRT-LM engine + Metal accelerator + TopK Metal sampler
        // + Gemma constraint provider. Updated via `./scripts/release.sh vX.Y.Z` on the
        // private kellyvv/LiteRTLM-iOSNative build pipeline.
        //
        .binaryTarget(
            name: "CLiteRTLM",
            url: "https://github.com/kellyvv/PhoneClawEngine/releases/download/v0.1.0/LiteRTLM.xcframework.zip",
            checksum: "d0ea7a94fa2349a0a6e11952911468324fddbd04bf121c393b589d407e41a535"
        ),
        .target(
            name: "PhoneClawEngine",
            dependencies: ["CLiteRTLM"],
            path: "Sources/PhoneClawEngine"
        ),
    ]
)
