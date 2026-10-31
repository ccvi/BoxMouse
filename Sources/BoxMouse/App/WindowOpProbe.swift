import AppKit

// ============================================================
// 诊断入口：对当前最前台窗口执行一次窗口操作，打印执行前后的实际 frame
//
//   BoxMouse --windowop leftHalf
//
// 为什么要有这个：平铺的几何算对了，不等于 AX 真的把窗口摆过去了——
// 有的应用会按自己的最小尺寸约束位置，有的直接拒绝改尺寸，全屏时更是完全不响应。
// 这些光看代码和自检都发现不了，必须落到一个真窗口上看坐标。
// ============================================================

@MainActor
enum WindowOpProbe {

    static func run(_ raw: String) {
        guard let op = WindowOp(rawValue: raw) else {
            print("未知操作：\(raw)")
            print("可用：" + WindowOp.allCases.map(\.rawValue).joined(separator: " "))
            exit(2)
        }
        guard AXIsProcessTrusted() else {
            print("没有辅助功能权限，读不到窗口坐标")
            exit(3)
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            print("没有前台应用")
            exit(4)
        }
        let pid = front.processIdentifier
        guard let window = TargetResolver.focusedWindow(pid: pid) else {
            print("拿不到 \(front.localizedName ?? "?") 的主窗口")
            exit(5)
        }

        print("应用：\(front.localizedName ?? "?")（pid \(pid)）")
        print("操作：\(op.displayName) [\(op.rawValue)]")
        print("执行前：\(describe(window))")

        let context = TargetContext(bundleID: front.bundleIdentifier, pid: pid, window: window)
        let ok = ActionRunner.shared.perform(.window(op), context: context)
        print("返回值：\(ok ? "成功" : "失败")")

        // AX 改 frame 有时要等一拍才反映出来；全屏那一支本来就是延迟 0.45s 再摆的
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))

        print("执行后：\(describe(window))")
        if let visible = hostVisibleFrame(window) {
            print("可用区：\(rectString(visible))")
        }
        exit(ok ? 0 : 1)
    }

    // MARK: - 读数

    private static func describe(_ window: AXUIElement) -> String {
        guard let frame = windowFrame(window) else { return "读不到 position/size" }
        return rectString(frame)
    }

    private static func rectString(_ rect: CGRect) -> String {
        String(format: "x=%.0f y=%.0f w=%.0f h=%.0f",
               rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    private static func windowFrame(_ window: AXUIElement) -> CGRect? {
        guard let positionRef = attribute(window, kAXPositionAttribute as CFString),
              let sizeRef = attribute(window, kAXSizeAttribute as CFString),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// 窗口所在那块屏的可用区（NS 坐标），仅供人肉核对
    private static func hostVisibleFrame(_ window: AXUIElement) -> CGRect? {
        guard let frame = windowFrame(window),
              let main = NSScreen.screens.first else { return nil }
        let flipBase = main.frame.maxY
        let probe = CGPoint(x: frame.midX, y: flipBase - frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main
        return screen?.visibleFrame
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}
