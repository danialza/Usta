// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UstaMac",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "UstaMac", targets: ["UstaMac"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "UstaProto",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/UstaProto",
            // usta.proto is symlinked into this directory from the repo
            // root. The grpc-swift-protobuf plugin discovers the .proto and
            // the adjacent grpc-swift-proto-generator-config.json file.
            plugins: [
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf"),
            ]
        ),
        .executableTarget(
            name: "UstaMac",
            dependencies: [
                "UstaProto",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/UstaMac",
            resources: [.process("Resources")]
        ),
    ]
)
