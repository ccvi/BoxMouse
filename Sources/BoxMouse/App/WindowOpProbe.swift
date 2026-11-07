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

        // 复现用户报的「执行两次才准」：
        //   先手动把窗口改成一个随便的尺寸（模拟拖拽窗口边缘），再连跑 N 次。
        // 手动改尺寸走的是**和产品代码不同的路径**（只设 size、不设 position），
        // 这样能区分「状态没跟上」和「一次 AX 写入没生效」两种成因。
        if let resize = resizeArgument(), let frame = windowFrame(window) {
            let manual = CGRect(x: frame.origin.x, y: frame.origin.y,
                                width: resize.width, height: resize.height)
            _ = setRawFrame(window, to: manual)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            print("手动改成：\(describe(window))")
        }

        let context = TargetContext(bundleID: front.bundleIdentifier, pid: pid, window: window)
        var ok = false
        for round in 1...repeatCount() {
            ok = ActionRunner.shared.perform(.window(op), context: context)
            print("第 \(round) 次返回值：\(ok ? "成功" : "失败")")
            // 采样轨迹：Chromium 的位置过渡约 160ms，只看首尾会错过中间态，
            // 也看不出「到底是没动、还是动到一半被打断」
            for tick in stride(from: 50, through: 1200, by: 50) {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                print(String(format: "  t+%4dms  %@", tick, describe(window)))
            }
            print("第 \(round) 次之后：\(describe(window))")
        }
        if let visible = hostVisibleFrame(window) {
            print("可用区：\(rectString(visible))")
        }
        exit(ok ? 0 : 1)
    }

    /// `--windowseq`：把「设 frame」拆成几种调用序列，逐条看哪一种一次就生效。
    ///
    /// 起因：Chromium / Electron 应用（Edge、WorkBuddy）上「居中 2/3」要执行两次才对，
    /// 原生 AppKit 应用（TextEdit）一次就对。差别只可能在 AX 写入的时序上，
    /// 所以把 `position → size → position` 拆开，每种组合都在「尺寸被人为改坏」
    /// 的同一前置状态下试一遍，谁一次成功一目了然。
    static func runSequence() {
        guard AXIsProcessTrusted() else {
            print("没有辅助功能权限"); exit(3)
        }
        guard let front = NSWorkspace.shared.frontmostApplication,
              let window = TargetResolver.focusedWindow(pid: front.processIdentifier),
              let host = hostVisibleFrame(window),
              let main = NSScreen.screens.first else {
            print("拿不到前台窗口"); exit(4)
        }
        let flipBase = main.frame.maxY
        let axVisible = CGRect(x: host.minX,
                               y: flipBase - host.maxY,
                               width: host.width,
                               height: host.height)
        guard let target = ActionRunner.tileFrame(.rightTwoThirds,
                                                 in: host,
                                                 flipBase: flipBase) else {
            print("算不出目标矩形"); exit(5)
        }
        print("应用：\(front.localizedName ?? "?")")
        print("可用区（AX）：\(rectString(axVisible))")
        print("目标：\(rectString(target))")

        // 看这个窗口到底认哪些属性。位置和尺寸分开写会互相覆盖（Chromium 的
        // bounds 变更有约 200ms 的过渡），如果它认 `AXFrame` 就能一次原子写完，
        // 那才是没有两段动作的正解。
        var names: CFArray?
        if AXUIElementCopyAttributeNames(window, &names) == .success,
           let list = names as? [String] {
            let interesting = list.filter {
                $0.contains("Position") || $0.contains("Size") || $0.contains("Frame")
                    || $0.contains("Bounds")
            }
            print("位置/尺寸类属性：\(interesting.joined(separator: ", "))")
        }

        // 前置状态：固定成「左半屏」——位置 x=0、尺寸 855 宽。
        // 目标「右 2/3」是 x=570、1140 宽，位置和尺寸**都必须变**，
        // 这样才分得清"谁生效了、谁被覆盖了"。
        // 之前拿「居中 2/3」当目标，而窗口本来就在 x=285，等于根本没测 position。
        func reset() {
            var origin = CGPoint(x: axVisible.minX, y: axVisible.minY)
            var size = CGSize(width: (axVisible.width / 2).rounded(.down),
                              height: axVisible.height)
            if let ov = AXValueCreate(.cgPoint, &origin),
               let sv = AXValueCreate(.cgSize, &size) {
                // 🔴 reset 自己也要分步 + 等待，否则它会被上一个用例的动画掐在中间，
                // 下一行的"前"就是脏的（第一版实验就栽在这：读到 x=236 / 457 这种中间值）
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, ov)
                RunLoop.current.run(until: Date().addingTimeInterval(0.30))
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sv)
                RunLoop.current.run(until: Date().addingTimeInterval(0.30))
            }
        }

        func apply(_ steps: [ProbeStep]) {
            applyRaw(window, steps: steps, target: target)
            // 读回要留时间：Chromium 的 bounds 回写是异步的，太早读会撒谎
            RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        }

        let cases: [(String, [ProbeStep])] = [
            ("只 position（看轨迹）", [.position]),
            ("pos → 40ms → 80ms → 120ms → 160ms → 200ms → 240ms",
             [.position, .wait(0.04), .realBounds, .wait(0.04), .realBounds,
              .wait(0.04), .realBounds, .wait(0.04), .realBounds,
              .wait(0.04), .realBounds, .wait(0.04), .realBounds])
        ]
        for (name, steps) in cases {
            reset()
            let before = describe(window)
            apply(steps)
            let after = describe(window)
            print("\(name.padding(toLength: 28, withPad: " ", startingAt: 0)) 前 \(before) → 后 \(after)")
        }
        exit(0)
    }

    /// 按给定顺序写 position / size（都写目标矩形），不做任何重试
    private static func applyRaw(_ window: AXUIElement, steps: [ProbeStep], target: CGRect) {
        var origin = target.origin
        var size = target.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
              let sizeValue = AXValueCreate(.cgSize, &size) else { return }
        for step in steps {
            switch step {
            case .position:
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
            case .size:
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            case let .wait(seconds):
                RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            case .read:
                print("    AX 读回：\(rectString(windowFrameOf(window)))")
            case .realBounds:
                let owner = pidOf(window)
                let real = owner.flatMap { renderedBounds(pid: $0) }
                print("    实际渲染：\(real.map(rectString) ?? "读不到")")
            case .frame:
                var rect = target
                guard let value = AXValueCreate(.cgRect, &rect) else { return }
                let result = AXUIElementSetAttributeValue(window,
                                                          "AXFrame" as CFString,
                                                          value)
                print("    AXFrame 写入返回：\(result.rawValue)")
            }
        }
    }

    private static func pidOf(_ window: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(window, &pid) == .success ? pid : nil
    }

    /// 合成器层面的真实窗口位置。AX 的 position 在写入后**立刻**就报目标值，
    /// 看不出过渡；CGWindowList 给的是屏幕上实际渲染的 bounds。
    private static func renderedBounds(pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        var best: CGRect?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 200, h > 200 else { continue }
            let rect = CGRect(x: x, y: y, width: w, height: h)
            if best == nil || rect.width * rect.height > best!.width * best!.height {
                best = rect
            }
        }
        return best
    }

    private static func windowFrameOf(_ window: AXUIElement) -> CGRect {
        guard let positionRef = attribute(window, kAXPositionAttribute as CFString),
              let sizeRef = attribute(window, kAXSizeAttribute as CFString),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return .zero }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return .zero }
        return CGRect(origin: origin, size: size)
    }

    /// 序列实验里的一步
    private enum ProbeStep {
        case position
        case size
        /// 停顿若干秒（模拟"让应用把 AX 变更 settle 完"）
        case wait(Double)
        /// 原子写 AXFrame（位置 + 尺寸一次到位）
        case frame
        /// 读一次当前 frame（验证"读会不会取消待应用的写入"）
        case read
        /// 读**真实渲染位置**（CGWindowList，能反映过渡中间态）
        case realBounds
    }

    /// `--repeat N`：连跑几次（默认 1）
    private static func repeatCount() -> Int {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--repeat"),
              index + 1 < args.count,
              let value = Int(args[index + 1]), value > 0 else { return 1 }
        return min(value, 5)
    }

    /// `--resize w,h`：先把窗口手动改成这个尺寸（模拟用户拖窗口边缘）
    private static func resizeArgument() -> CGSize? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--resize"),
              index + 1 < args.count else { return nil }
        let parts = args[index + 1].split(separator: ",")
        guard parts.count == 2,
              let w = Double(parts[0]), let h = Double(parts[1]),
              w > 100, h > 100 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// 只设尺寸、不动位置——AX 改 size 的锚点是左下角，位置会跟着飘，
    /// 但这里只关心"尺寸被外因改过了"这个前置条件。
    @discardableResult
    private static func setRawFrame(_ window: AXUIElement, to rect: CGRect) -> Bool {
        var size = rect.size
        guard let sizeValue = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(window,
                                            kAXSizeAttribute as CFString,
                                            sizeValue) == .success
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
