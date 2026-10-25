// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PaperNAS",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PaperNAS", targets: ["PaperNAS"])],
    targets: [
        .executableTarget(name: "PaperNAS", resources: [.copy("Resources")],
                          linkerSettings: [.linkedFramework("SwiftUI"), .linkedFramework("AppKit"),
                                           .linkedFramework("PDFKit"), .linkedFramework("WebKit"),
                                           .linkedFramework("Security")]),
        .testTarget(name: "PaperNASTests", dependencies: ["PaperNAS"])
    ],
    swiftLanguageModes: [.v5]
)
