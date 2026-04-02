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
    targets: [
        .target(
            name: "AppStoreBillingLibrary",
            path: "Sources/AppStoreBillingLibrary"
        )
    ]
)
