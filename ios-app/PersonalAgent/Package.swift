// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PersonalAgent",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "PersonalAgent", targets: ["PersonalAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "PersonalAgent",
            dependencies: ["SwiftTerm"],
            path: "Sources"
        )
    ]
)
