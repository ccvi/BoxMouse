import Foundation

// ============================================================
// 诊断：应用扫描到底要多久
//
//   .build/debug/BoxMouse --scanapps [次数，默认 3]
//
// 为什么要有这个：这个扫描是「添加应用」面板每次打开的必经之路，
// 也是"打开手势编辑器（打开应用那项）"的必经之路。
// 它慢过一阵子：枚举器没在 .app 处剪枝，钻进每个包内部，
// /Applications 一个根就是 40 万条目、8.2 秒。肉眼只知道"转圈很久"，
// 看不出是枚举慢还是读 Info.plist 慢，所以把耗时和条目数打出来。
// ============================================================

enum ScanProbe {

    static func run(rounds: Int = 3) {
        var apps: [InstalledApp] = []
        for index in 1...max(1, rounds) {
            let start = Date()
            apps = InstalledApps.scan()
            let cost = Date().timeIntervalSince(start) * 1000
            print(String(format: "第 %d 次：%d 个应用，%.0f ms", index, apps.count, cost))
        }

        // 剪枝是否生效的硬证据：结果里不该出现 "Xxx.app/Contents/..." 这种嵌套包。
        // 替身解析出来的不算——豆包浏览器本来就在 Doubao.app/Contents/Helpers 里。
        let nested = apps.filter { $0.path.contains(".app/") && !$0.viaAlias }
        print(nested.isEmpty
              ? "嵌套包：0 个（剪枝生效）"
              : "⚠ 嵌套包：\(nested.count) 个（剪枝漏了）")
        for item in nested.prefix(3) { print("    " + item.path) }

        let aliased = apps.filter(\.viaAlias)
        if !aliased.isEmpty {
            print("替身解析：\(aliased.count) 个（" +
                  aliased.prefix(3).map(\.name).joined(separator: "、") + "）")
        }

        print("────────────────────────────────────────")
        for app in apps.prefix(5) {
            print("  \(app.name)  \(app.bundleID)")
        }
        print("  …共 \(apps.count) 个")
    }
}
