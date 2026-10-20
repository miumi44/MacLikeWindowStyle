// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "WindowBridge", platforms: [.macOS(.v14)], products: [.executable(name: "WindowBridge", targets: ["WindowBridge"])], targets: [.target(name: "WindowBridgeCore"), .executableTarget(name: "WindowBridge", dependencies: ["WindowBridgeCore"])])
