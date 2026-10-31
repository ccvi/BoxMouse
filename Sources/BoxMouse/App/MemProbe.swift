import AppKit

// ============================================================
// 内存专项测量（诊断用，不是产品路径）
//
// 为什么必须在进程内测：
// 浮层的生命周期只有「按住拖动的那几百毫秒」。从外面用 `footprint` 采样，
// 要么错过那一瞬，要么被别的进程/页缓存干扰；`vmmap` 更糟——它把预加载映射
// 也算进来，数字大得没法用。这里直接读 `task_info(TASK_VM_INFO)` 的
// phys_footprint（就是活动监视器里那个"内存"），精确到 KB，并且能把
// 「绘制中 / 刚隐藏 / 循环 N 次后 / 静置」四个时刻分开量化。
//
// 用法：
//   .build/debug/BoxMouse --memprobe [循环次数，默认 20]
// ============================================================

@MainActor
enum MemProbe {

    struct Sample {
        let label: String
        let phys: Double        // MB，当前
        let peak: Double        // MB，进程历史峰值
        let compressed: Double  // MB
        let resident: Double    // MB
        let appWindows: Int     // NSApp.windows（AppKit 侧是否还持有）
        let serverWindows: Int  // WindowServer 侧真实窗口数
    }

    static func run(rounds: Int) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()

        let screen = NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let size = screen?.frame.size ?? CGSize(width: 1710, height: 1107)

        print("== BoxMouse 轨迹浮层内存专项 ==")
        print("屏幕 \(Int(size.width))×\(Int(size.height)) pt，backingScale \(scale)")
        print("单块全屏 backing store 理论值 "
              + String(format: "%.1f MB", size.width * size.height * scale * scale * 4 / 1_048_576))
        print("")
        printRow("阶段", phys: "当前", peak: "峰值", compressed: "压缩",
                 resident: "常驻", appWindows: "NSApp", serverWindows: "WS")

        let overlay = TrailOverlay()
        let anchor = CGPoint(x: size.width / 2, y: size.height / 2)

        // ---- 0 启动基线 ----
        pump(1.2)
        let base = sample("0 启动基线")
        printSample(base)

        // ---- 1 浮层显示中（不隐藏）：对应「按住右键正在画」那一刻 ----
        overlay.show(at: anchor, color: .systemRed, width: 3)
        for i in 0..<24 {
            overlay.append(CGPoint(x: anchor.x + CGFloat(i) * 6,
                                   y: anchor.y + CGFloat(sin(Double(i) / 3) * 40)))
        }
        pump(0.4)
        let shown = sample("1 浮层显示中")
        printSample(shown)

        // ---- 2 隐藏后：窗口对象应该被释放 ----
        overlay.hide()
        pump(0.6)
        let hidden = sample("2 隐藏后 0.6s")
        printSample(hidden)

        // ---- 3 反复 show/hide：看是否线性爬升（泄漏）还是回到稳态 ----
        var curve: [Sample] = []
        for i in 1...rounds {
            overlay.show(at: anchor, color: .systemRed, width: 3)
            for j in 0..<16 {
                overlay.append(CGPoint(x: anchor.x + CGFloat(j) * 7,
                                       y: anchor.y + CGFloat(j % 5) * 6))
            }
            pump(0.06)
            overlay.hide()
            pump(0.06)
            if i % max(1, rounds / 4) == 0 || i == rounds {
                let s = sample("3 第 \(i) 轮后")
                curve.append(s)
                printSample(s)
            }
        }

        // ---- 4 静置：系统有没有把刚才那些临时分配收回去 ----
        pump(3.0)
        let settled = sample("4 静置 3s")
        printSample(settled)
        print("")

        // ---- 结论 ----
        let oneTime = shown.phys - base.phys
        let residual = settled.phys - base.phys
        let driftPerRound = rounds > 1
            ? (curve.last!.phys - curve.first!.phys) / Double(max(1, curve.count - 1))
            : 0

        print("—— 读数 ——")
        print(String(format: "显示中一次性抬升     %+.1f MB（≈ %.1f 块全屏 backing store）",
                     oneTime, oneTime / max(0.1, theoreticalBackingMB(size, scale))))
        print(String(format: "隐藏后残留           %+.1f MB（窗口是否真被释放看这里）",
                     hidden.phys - base.phys))
        print(String(format: "静置后残留           %+.1f MB", residual))
        print(String(format: "峰值（进程历史最高） %.1f MB，基线 %.1f MB，差 %+.1f MB",
                     peakNow(), base.phys, peakNow() - base.phys))
        print(String(format: "跨采样点漂移         %+.2f MB/采样点", driftPerRound))
        print("")

        let leaked = residual > 8 && driftPerRound > 0.5
        if leaked {
            print("判定：⚠️ 有累积迹象——反复触发后残留不回落，窗口没被真正释放，需要改成复用窗口。")
        } else if oneTime > 15 {
            print(String(format: "判定：窗口是瞬时大头（%.0f MB），但会释放；峰值来自「绘制那一瞬」，不是泄漏。", oneTime))
        } else {
            print(String(format: "判定：轨迹浮层不是内存峰值的主因（瞬时 %.0f MB，且能释放）。", oneTime))
        }
    }

    // MARK: - 单场景测量（一次进程只测一种窗口形态）
    //
    // 为什么要一次一进程：浮层用过的 surface 一旦分配就不还给系统，
    // 同一个进程里连测几种形态，后一种的基线已经被前一种抬高了，读数没法比。
    //
    //   --memprobe-shot <宽> <高> <帧数> <1=增量重绘 / 0=整屏重绘>

    static func runShot(width: CGFloat, height: CGFloat, frames: Int, incremental: Bool) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        pump(0.9)

        let base = readVM().phys

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: .borderless,
                              backing: .buffered,
                              defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                     .fullScreenAuxiliary, .ignoresCycle]

        let view = ProbeTrailView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.incremental = incremental
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: 0, y: 0))
        window.orderFrontRegardless()
        pump(0.15)

        // 和真实手势同样的节奏：约 60 帧、每帧 16ms，轨迹横跨整个窗口
        for frame in 0..<max(2, frames) {
            let t = CGFloat(frame) / CGFloat(max(1, frames - 1))
            let point = CGPoint(x: 12 + t * (width - 24),
                                y: height / 2 + CGFloat(sin(Double(t) * 12)) * height * 0.22)
            if frame == 0 {
                view.begin(point)
            } else {
                view.add(point)
            }
            pump(0.016)
        }
        pump(0.2)
        let during = readVM().phys

        window.orderOut(nil)
        pump(0.5)
        let after = readVM().phys

        print(String(format: "SHOT %dx%d frames=%d inc=%d  base=%.1f  during=%.1f (+%.1f)  after=%.1f (+%.1f)",
                     Int(width), Int(height), frames, incremental ? 1 : 0,
                     base, during, during - base, after, after - base))
        fflush(stdout)
    }

    // MARK: - 采样

    private static func sample(_ label: String) -> Sample {
        let vm = readVM()
        return Sample(label: label,
                      phys: vm.phys,
                      peak: vm.peak,
                      compressed: vm.compressed,
                      resident: vm.resident,
                      appWindows: NSApp.windows.count,
                      serverWindows: serverWindowCount())
    }

    private static func printRow(_ label: String, phys: String, peak: String,
                                 compressed: String, resident: String,
                                 appWindows: String, serverWindows: String) {
        print(String(format: "%-16@ %8@ %8@ %8@ %8@ %5@ %4@",
                     label as NSString, phys as NSString, peak as NSString,
                     compressed as NSString, resident as NSString,
                     appWindows as NSString, serverWindows as NSString))
    }

    private static func printSample(_ s: Sample) {
        printRow(s.label,
                 phys: String(format: "%.1f", s.phys),
                 peak: String(format: "%.1f", s.peak),
                 compressed: String(format: "%.1f", s.compressed),
                 resident: String(format: "%.1f", s.resident),
                 appWindows: "\(s.appWindows)",
                 serverWindows: "\(s.serverWindows)")
        fflush(stdout)
    }

    // MARK: - 系统读数

    private struct VM {
        var phys: Double = 0
        var peak: Double = 0
        var compressed: Double = 0
        var resident: Double = 0
    }

    private static func readVM() -> VM {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return VM() }
        let mb = 1_048_576.0
        return VM(phys: Double(info.phys_footprint) / mb,
                  peak: Double(info.ledger_phys_footprint_peak) / mb,
                  compressed: Double(info.compressed) / mb,
                  resident: Double(info.resident_size) / mb)
    }

    private static func peakNow() -> Double {
        readVM().peak
    }

    /// WindowServer 侧真正存在的窗口数（按宿主 pid 过滤）。
    /// 只看 NSApp.windows 会骗人：对象释放了、窗口却还挂在服务器上时它看不出来。
    private static func serverWindowCount() -> Int {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]] else { return -1 }
        let pid = getpid()
        return list.reduce(into: 0) { total, info in
            if (info[kCGWindowOwnerPID as String] as? Int32) == pid { total += 1 }
        }
    }

    private static func theoreticalBackingMB(_ size: CGSize, _ scale: CGFloat) -> Double {
        size.width * size.height * scale * scale * 4 / 1_048_576
    }

    /// 跑一段事件循环，让 CoreAnimation / WindowServer 的事务真正提交。
    /// 不跑 runloop 直接读内存，窗口还没被合成，backing store 可能一个字节都没分配。
    private static func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
            CATransaction.flush()
        }
    }
}

/// 场景用的最小轨迹视图：和产品里 TrailView 的画法与重绘策略一致，
/// 只是可以指定窗口尺寸和「整屏重绘 / 增量重绘」，用来分离两个变量。
private final class ProbeTrailView: NSView {

    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3
    var incremental = true

    private var points: [CGPoint] = []

    override var isFlipped: Bool { true }

    func begin(_ point: CGPoint) {
        points = [point]
        setNeedsDisplay(NSRect(x: point.x - lineWidth * 2, y: point.y - lineWidth * 2,
                               width: lineWidth * 4, height: lineWidth * 4))
    }

    func add(_ point: CGPoint) {
        let previous = points.last ?? point
        points.append(point)
        if incremental {
            let pad = lineWidth * 2
            setNeedsDisplay(NSRect(x: min(previous.x, point.x) - pad,
                                   y: min(previous.y, point.y) - pad,
                                   width: abs(point.x - previous.x) + pad * 2,
                                   height: abs(point.y - previous.y) + pad * 2))
        } else {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        color.withAlphaComponent(0.92).setStroke()
        path.stroke()
    }
}
