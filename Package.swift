// swift-tools-version:5.9
// 启动台助手 Launchy —— 用 Xcode 直接打开这个文件夹（或 Package.swift）即可编译运行。
import PackageDescription

let package = Package(
    name: "Launchy",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Launchy",
            path: "Sources/Launchy"
        )
    ]
)
