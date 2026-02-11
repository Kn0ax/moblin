// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LibDataChannelPackage",
    platforms: [
        .iOS(.v15),
        .macCatalyst(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "libdatachannel", targets: ["libdatachannel"]),
    ],
    targets: [
        .binaryTarget(
            name: "libdatachannel",
            url: "https://github.com/HaishinKit/libdatachannel-xcframework/releases/download/v0.24.0/libdatachannel.xcframework.zip",
            checksum: "52163eed2c9d652d913b20d1fd5a1925c5982b1dcdf335fd916c72ffa385bb26"
        ),
    ]
)
