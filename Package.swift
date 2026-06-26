// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "BvfAppKit",
  platforms: [
    .macOS(.v15),
    .iOS(.v18)
  ],
  products: [
    .library(
      name: "BvfAppKit",
      targets: ["BvfAppKit"]
    ),
    .library(
      name: "BvfAppKitDecrypt",
      targets: ["BvfAppKitDecrypt"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/openbvf/BvfKit.git", .upToNextMinor(from: "0.1.3"))
  ],
  targets: [
    .target(
      name: "BvfAppKit",
      dependencies: [
        .product(name: "BvfKit", package: "BvfKit")
      ]
    ),
    .target(
      name: "BvfAppKitDecrypt",
      dependencies: [
        "BvfAppKit",
        .product(name: "BvfKit", package: "BvfKit")
      ]
    ),
    .testTarget(
      name: "BvfAppKitTests",
      dependencies: ["BvfAppKitDecrypt", .product(name: "BvfKit", package: "BvfKit")]
    ),
  ]
)
