// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AnkerVoiceBridge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "anker-voice-bridge", targets: ["AnkerVoiceBridge"]),
        .executable(name: "anker-button-voice", targets: ["AnkerButtonVoice"])
    ],
    targets: [
        .target(name: "OpenBeanKit"),
        .executableTarget(
            name: "AnkerVoiceBridge",
            dependencies: ["OpenBeanKit"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Support/Info.plist"
            ])]
        ),
        .executableTarget(
            name: "AnkerButtonVoice",
            dependencies: ["OpenBeanKit"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist", "-Xlinker", "Support/ButtonInfo.plist"
            ])]
        ),
        .testTarget(name: "OpenBeanKitTests", dependencies: ["OpenBeanKit"])
    ]
)
