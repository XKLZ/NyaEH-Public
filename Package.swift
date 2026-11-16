// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "NyaEH",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "NyaEHCore", targets: ["NyaEHCore"]),
        .executable(name: "NyaEHDevRunner", targets: ["NyaEHDevRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "NyaEHCore",
            dependencies: [
                "CSQLiteVec",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .target(
            name: "CSQLiteVec",
            cSettings: [
                .define("SQLITE_CORE"),
                .define("SQLITE_VEC_STATIC"),
                .define("SQLITE_VEC_OMIT_FS")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "NyaEHDevRunner",
            dependencies: ["NyaEHCore"]
        ),
        .testTarget(
            name: "NyaEHCoreTests",
            dependencies: [
                "NyaEHCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ]
)
