// swift-tools-version: 5.10
import PackageDescription

// BoxMouse —— 本地运行的 macOS 鼠标手势自动化工具。
//
// platform 写 .v14 而不是 .v26，与家族其他项目一致：本项目用到的能力
// （CGEventTap / AXUIElement / NSWorkspace / SwiftUI）在 14 上都有，
// 抬到 26 换不到任何东西，却让它在 14/15 上一行都跑不起来。
//
// 零第三方依赖：
//   · 手势采集走 CGEventTap（需要辅助功能授权）
//   · 窗口关闭/最小化走 AXUIElement
//   · 媒体键走 NSSystemDefined 合成事件
//
// 不声明 testTarget：本机只有 Command Line Tools，声明了会因缺 XCTest
// 连主程序都编不过。自检走应用内 --selftest，build-app.sh 拿它当发布门禁。
let package = Package(
    name: "BoxMouse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "BoxMouse", targets: ["BoxMouse"])
    ],
    targets: [
        .executableTarget(
            name: "BoxMouse",
            path: "Sources/BoxMouse"
        )
    ]
)
