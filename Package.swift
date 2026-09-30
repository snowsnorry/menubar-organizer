// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenubarOrganizer",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "MenubarOrganizer", targets: ["MenubarOrganizer"])
    ],
    targets: [
        .target(name: "OrganizerCore"),
        .executableTarget(name: "MenubarOrganizer", dependencies: ["OrganizerCore"], resources: [.process("Resources")]),
        .testTarget(name: "OrganizerCoreTests", dependencies: ["OrganizerCore"]),
        .testTarget(name: "MenubarOrganizerTests", dependencies: ["MenubarOrganizer", "OrganizerCore"])
    ]
)
