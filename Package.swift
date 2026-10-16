// swift-tools-version:5.9
// 启动台助手 Launchy —— 用 Xcode 直接打开这个文件夹（或 Package.swift）即可编译运行。
import PackageDescription

let package = Package(
    name: "Launchy",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 自动更新
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Launchy",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Launchy",
            linkerSettings: [
                // 打包成 .app 后，Sparkle.framework 放在 Contents/Frameworks
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
