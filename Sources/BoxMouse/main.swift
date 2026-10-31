import AppKit

// ============================================================
// 入口
//
// 自检必须在 NSApplication.run() 之前拦掉：跑进事件循环后
// --selftest 会变成一个看不到结果、也退不出来的 GUI 进程。
// ============================================================

if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { SelfTest.run() })
}

// 诊断开关：对当前前台窗口执行一次窗口操作，打印前后实际坐标
//   .build/debug/BoxMouse --windowop leftHalf
if let index = CommandLine.arguments.firstIndex(of: "--windowop"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated { WindowOpProbe.run(CommandLine.arguments[index + 1]) }
    exit(0)
}

// 诊断开关：内存专项测量（轨迹浮层那个全屏透明窗口的成本与泄漏）
//   .build/debug/BoxMouse --memprobe [循环次数]
//   .build/debug/BoxMouse --memprobe-shot <宽> <高> <帧数> <1=增量/0=整屏>
if let index = CommandLine.arguments.firstIndex(of: "--memprobe-shot") {
    let args = CommandLine.arguments
    let width = args.count > index + 1 ? (Double(args[index + 1]) ?? 1710) : 1710
    let height = args.count > index + 2 ? (Double(args[index + 2]) ?? 1107) : 1107
    let frames = args.count > index + 3 ? (Int(args[index + 3]) ?? 60) : 60
    let incremental = args.count > index + 4 ? (args[index + 4] != "0") : true
    MainActor.assumeIsolated {
        MemProbe.runShot(width: width, height: height,
                         frames: frames, incremental: incremental)
    }
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--memprobe") {
    let rounds = CommandLine.arguments.count > index + 1
        ? (Int(CommandLine.arguments[index + 1]) ?? 20) : 20
    MainActor.assumeIsolated { MemProbe.run(rounds: rounds) }
    exit(0)
}

// 诊断开关：列出库里有哪两条鼠标手势互相像到会打架
//   .build/debug/BoxMouse --pathdiff [阈值]     全库冲突列表
//   .build/debug/BoxMouse --pathdiff <手势名>   单条：与全库排行 + 手绘变体命中率
if let index = CommandLine.arguments.firstIndex(of: "--pathdiff") {
    let argument = CommandLine.arguments.count > index + 1
        ? CommandLine.arguments[index + 1] : ""
    if let threshold = Double(argument) {
        MainActor.assumeIsolated { PathDiffProbe.run(threshold: threshold) }
    } else if !argument.isEmpty {
        MainActor.assumeIsolated { PathDiffProbe.runOne(argument) }
    } else {
        MainActor.assumeIsolated { PathDiffProbe.run() }
    }
    exit(0)
}

// 诊断开关：采集触摸板原始帧，判定手势为什么没触发（见 TrackpadProbe）
if let index = CommandLine.arguments.firstIndex(of: "--trackpad-probe") {
    let seconds = CommandLine.arguments.count > index + 1
        ? (Double(CommandLine.arguments[index + 1]) ?? 20) : 20
    TrackpadProbe.run(seconds: seconds)
}

// 诊断开关：把菜单栏字形放大写成 PNG，肉眼确认 18pt 下能不能读出来
if let index = CommandLine.arguments.firstIndex(of: "--dump-menubar-icon"),
   CommandLine.arguments.count > index + 1 {
    MainActor.assumeIsolated {
        MenuBarIcon.dumpPreview(to: CommandLine.arguments[index + 1])
    }
    exit(0)
}

// 诊断开关：把所有字形变体各导一张（<前缀>-0.png …），用来横向比对
if let index = CommandLine.arguments.firstIndex(of: "--dump-menubar-variants"),
   CommandLine.arguments.count > index + 1 {
    let prefix = CommandLine.arguments[index + 1]
    MainActor.assumeIsolated {
        for variant in MenuBarGlyphVariant.allCases {
            MenuBarIcon.dumpPreview(to: "\(prefix)-\(variant.rawValue).png",
                                    scale: 10,
                                    variant: variant,
                                    tint: .white)
            MenuBarIcon.dumpStrip(to: "\(prefix)-bar-\(variant.rawValue).png", variant: variant)
        }
    }
    exit(0)
}

// 诊断开关：应用扫描耗时（"添加应用"面板每次打开都会扫一遍）
//   .build/debug/BoxMouse --scanapps [次数]
if let index = CommandLine.arguments.firstIndex(of: "--scanapps") {
    let rounds = CommandLine.arguments.count > index + 1
        ? (Int(CommandLine.arguments[index + 1]) ?? 3) : 3
    ScanProbe.run(rounds: rounds)
    exit(0)
}

//   .build/debug/BoxMouse --memrelief [MB]  ← 量 malloc 到底肯还多少
if let index = CommandLine.arguments.firstIndex(of: "--memrelief") {
    let megabytes = CommandLine.arguments.count > index + 1
        ? (Int(CommandLine.arguments[index + 1]) ?? 200) : 200
    exit(MemReliefProbe.run(megabytes: max(1, megabytes)))
}

if CommandLine.arguments.contains("--version") {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    print(version)
    exit(0)
}

let application = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
// 裸可执行文件（swift run / .build 产物）没有 bundle 里的 LSUIElement，
// 显式设成 regular，行为才和 .app 里一致。
application.setActivationPolicy(.regular)
application.run()
