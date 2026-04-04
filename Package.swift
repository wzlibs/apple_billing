// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AppStoreBillingLibrary",
    platforms: [
        .iOS(.v15)   // StoreKit 2 requires iOS 15+
    ],
    products: [
        .library(
            name: "AppStoreBillingLibrary",
            targets: ["AppStoreBillingLibrary"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/adjust/ios_sdk",
            from: "5.0.0"
        )
    ],
    targets: [
        .target(
            name: "AppStoreBillingLibrary",
            dependencies: [
                .product(name: "Adjust", package: "ios_sdk")
            ],
            path: "Sources/AppStoreBillingLibrary"
        )
    ]
)
