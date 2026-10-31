import Foundation
import AppKit
import Darwin

// ============================================================
// 触摸板手势引擎
//
// 为什么不用公开 API：`NSEvent` 的 .swipe / .magnify 只给方向和倍率，
// **拿不到"几根手指"**，做不了「3 指轻点 vs 4 指轻点」。所以这里走
// MultitouchSupport（BetterTouchTool 同一路线），它逐帧给出触点数量和
// 归一化坐标，手指数就是回调参数，不用猜。
//
// 五条必须守住的：
// 1) 框架是私有的 → **动态加载**。加载失败就把整个功能静默关掉，
//    绝不能让 app 起不来。
// 2) 回调跑在触控板自己的线程，**不能在里面做界面的事**，
//    识别完的结果统一 DispatchQueue.main.async 回去。
// 3) 触点结构是逆向来的 → **坐标只做合理性校验**（防读到垃圾），
//    不做 0…1 范围假设：不同版本给过 0…1、-1…1 两套原点，
//    卡死范围会把坐标全丢光，滑动就永远识别不出来。
// 4) 🔴 **不能依赖"手指数变成 0"的收尾帧**。实测手指全抬起之后
//    并不保证再来一帧 count=0，只靠抬手判轻点等于轻点永远不触发。
//    所以滑动/捏合在过程内即时判定，轻点由超时兜底（见 settle）。
// 5) 回调线程与主线程的 Timer 都会碰识别器 → 用一把锁，不玩无锁。
// ============================================================

/// MultitouchSupport 触点结构里我们只用到的部分。
///
/// 已知偏移（64 位）：frame @0、timestamp @8、identifier @16、state @20、
/// fingerID @24、handID @28、normalized @32（position 的 x, y 两个 Float）。
///
/// 🔴 **步长不能写死**。公开流传的三套头文件给过三种结构体大小：
///   · 旧版 Finger  96 字节 = 24 个 Float
///   · 新版 Touch   88 字节 = 22 个 Float
///   · 更早的版本    72 字节 = 18 个 Float
/// 偏移（normalized 在 32）三家一致，**只有步长不同**——步长取错，
/// 第一根手指的坐标照样对，第二根开始就读到别的字段上（角度、面积…），
/// 于是"多指"永远识别不出来。
///
/// 所以这里不猜：运行时拿几套候选步长各读一遍，看哪一套能让**所有**触点
/// 的坐标都落在合理范围内，用那一套。首帧还会把实际步长写进日志。
private enum MTLayout {
    /// normalized.position 的 x 在结构体里的第几个 Float（字节 32）
    static let normalizedX = 8
    /// normalized.position 的 y
    static let normalizedY = 9
    /// 候选步长（Float 个数），按"新到旧"排
    static let candidateStrides = [22, 24, 18]
    /// 候选都不成立时（只有一根手指时无从判断）用这个
    static let fallbackStride = 22
    /// 坐标合理范围：归一化坐标理论上是 0…1，但不同系统给过 0…1 和 -1…1 两套原点
    static let maxAbs = 8.0
}

/// 识别出的触摸板手势
enum TrackpadEvent: Equatable {
    case tap(fingers: Int)
    case swipe(fingers: Int, direction: SwipeDirection)
    /// ratio > 1 = 张开，< 1 = 捏合
    case pinch(spreadRatio: Double)
    /// 单指画出的轨迹（y 已翻成屏幕方向：向下为正，与鼠标手势模板一致）。
    /// 坐标是触控板归一化单位（1.0 = 一条边），匹配前统一再归一化。
    case path([CGPoint])
}

/// 一次识别结果 + 起手那一刻的修饰键。
///
/// 修饰键只在**起手帧**读一次：手指落下时按着的键就是这条手势的条件，
/// 中途松手不该换一条手势（和鼠标手势是同一套语义）。
struct TrackpadReport: Equatable {
    var event: TrackpadEvent
    var fingers: Int
    var modifiers: Set<ModifierKey>

    var eventFingers: Int {
        switch event {
        case let .tap(f):             return f
        case let .swipe(f, _):        return f
        case .pinch:                  return 2
        case .path:                   return 1
        }
    }
}

/// 把连续触点帧收敛成一次手势。
///
/// 除了 start/stop 之外**不加锁**：调用方（TrackpadEngine）已经在锁内调它。
private final class TrackpadRecognizer {

    // 阈值（归一化单位：1.0 = 触控板的一条边）
    // 触控板约 10~11cm 宽，0.08 ≈ 8mm，0.12 ≈ 13mm
    private let tapMaxTravel: Double = 0.08
    private let tapMaxDuration: TimeInterval = 0.40
    private let swipeMinTravel: Double = 0.12
    private let pinchMinRatio: Double = 0.20
    /// 画轨迹的最小总长：触控板约 10~11cm，0.30 ≈ 3cm，
    /// 再短的"画"多半是想移动指针或者误触
    private let pathMinTravel: Double = 0.30

    private var active = false
    private var fingers = 0
    private var fingerCountChanged = false
    private var fired = false
    private var modifiers: Set<ModifierKey> = []
    private var startTime: TimeInterval = 0
    private var lastTime: TimeInterval = 0
    private var startCentroid = CGPoint.zero
    private var lastCentroid = CGPoint.zero
    private var startSpread: Double = 0
    private var lastSpread: Double = 0
    /// 这一轮有没有拿到过可信坐标。没有就只能判手指数，判不了方向。
    private var hasCoords = false
    /// 单指轨迹采集（画轨迹手势）。y 取负存：触控板 y 向远端为正，
    /// 屏幕坐标 y 向下为正，翻过来才跟鼠标手势的模板同一个方向。
    private var pathPoints: [CGPoint] = []

    /// 起手瞬间回调一次（手指落下的那一刻）。
    ///
    /// 修饰键按规则是「起手判一次」，所以**起手时读到什么，这一轮就用什么**。
    /// 日志里把这一行写出来，用户一划就知道修饰键到底解出来没有——
    /// 「配了 Fn 却读不到」这种事光看界面永远看不出来。
    var onStart: ((Set<ModifierKey>) -> Void)?

    /// 喂一帧。过程中能定的手势（滑动 / 捏合）在这里就返回，
    /// 不用等到抬手——抬手帧不一定来。
    func update(fingers incoming: Int,
                touches: [CGPoint],
                timestamp: TimeInterval,
                modifiers incomingModifiers: Set<ModifierKey>) -> TrackpadReport? {

        guard incoming >= 1 else {
            // 真拿到 count=0 就当场收尾，比等超时快
            let report = finish()
            reset()
            return report
        }

        if !active {
            active = true
            fingers = incoming
            fingerCountChanged = false
            fired = false
            modifiers = incomingModifiers
            onStart?(incomingModifiers)
            startTime = timestamp
            lastTime = timestamp
            startCentroid = centroid(of: touches)
            startSpread = spread(of: touches)
            hasCoords = touches.count >= 2
            lastCentroid = startCentroid
            lastSpread = startSpread
            pathPoints = []
            if incoming == 1, let first = touches.first {
                pathPoints.append(CGPoint(x: Double(first.x), y: Double(-first.y)))
            }
            return nil
        }

        // 过程中手指数变了（先放两指又补一指）→ 这一轮作废
        if incoming != fingers {
            fingerCountChanged = true
            return nil
        }

        lastTime = timestamp
        if touches.count >= 2 {
            hasCoords = true
            lastCentroid = centroid(of: touches)
            lastSpread = spread(of: touches)
        }
        // 单指轨迹：每帧采一个点，离上个点太近的丢掉（触控板帧率比手快得多）
        if fingers == 1, let point = touches.first {
            let flipped = CGPoint(x: Double(point.x), y: Double(-point.y))
            if let last = pathPoints.last,
               hypot(flipped.x - last.x, flipped.y - last.y) < 0.012 {
                // 太近，跳过
            } else {
                pathPoints.append(flipped)
            }
        }

        guard !fired else { return nil }
        if let event = detectDuring() {
            fired = true
            // 捏合没有"几根手指"的语义，统一记 2
            let count = { if case .pinch = event { return 2 } else { return fingers } }()
            return TrackpadReport(event: event, fingers: count, modifiers: modifiers)
        }
        return nil
    }

    /// 抬手 / 超时时收尾：单指还能判「画轨迹」，之后只剩「轻点」。
    func finish() -> TrackpadReport? {
        guard active, !fingerCountChanged, !fired else { return nil }
        fired = true

        // 单指画轨迹：点数和总长都够才当手势——轻点、小幅蹭动不该触发
        if fingers == 1, pathPoints.count >= 6,
           PathRecognizer.length(pathPoints) >= pathMinTravel {
            return TrackpadReport(event: .path(pathPoints), fingers: 1, modifiers: modifiers)
        }

        let duration = max(0, lastTime - startTime)
        // 时间戳单位如果不是秒（个别系统版本给的是毫秒），duration 会离谱地大。
        // 这种情况不判轻点，至少不会把一次轻点误当滑动。
        let saneDuration = duration > 0 && duration < 5
        guard saneDuration, duration <= tapMaxDuration else { return nil }

        let dx = Double(lastCentroid.x - startCentroid.x)
        let dy = Double(lastCentroid.y - startCentroid.y)
        if hasCoords, hypot(dx, dy) > tapMaxTravel { return nil }

        return TrackpadReport(event: .tap(fingers: fingers), fingers: fingers, modifiers: modifiers)
    }

    /// 过程中的即时判定：位移够大 → 滑动；两指间距变化够大 → 捏合。
    ///
    /// 单指不判滑动：单指在触控板上就是移动指针，判成手势会一路误触。
    private func detectDuring() -> TrackpadEvent? {
        guard hasCoords else { return nil }

        let dx = Double(lastCentroid.x - startCentroid.x)
        let dy = Double(lastCentroid.y - startCentroid.y)
        let travel = hypot(dx, dy)

        if fingers == 2, lastSpread > 0, startSpread > 0.02 {
            let ratio = lastSpread / startSpread
            if ratio >= 1 + pinchMinRatio || ratio <= 1 / (1 + pinchMinRatio) {
                return .pinch(spreadRatio: ratio)
            }
        }

        guard fingers >= 2, travel >= swipeMinTravel else { return nil }
        let direction: SwipeDirection
        if abs(dx) >= abs(dy) {
            direction = dx > 0 ? .right : .left
        } else {
            // 触控板坐标 y 轴朝远端为正：手指向屏幕上方滑 → dy > 0
            direction = dy > 0 ? .up : .down
        }
        return .swipe(fingers: fingers, direction: direction)
    }

    func reset() {
        active = false
        fingers = 0
        fingerCountChanged = false
        fired = false
        hasCoords = false
        startSpread = 0
        lastSpread = 0
        modifiers = []
        pathPoints = []
    }

    var isActive: Bool { active }

    private func centroid(of touches: [CGPoint]) -> CGPoint {
        guard !touches.isEmpty else { return lastCentroid }
        var x: CGFloat = 0, y: CGFloat = 0
        for point in touches {
            x += point.x
            y += point.y
        }
        let count = CGFloat(touches.count)
        return CGPoint(x: x / count, y: y / count)
    }

    private func spread(of touches: [CGPoint]) -> Double {
        guard touches.count == 2 else { return 0 }
        return Double(hypot(touches[0].x - touches[1].x, touches[0].y - touches[1].y))
    }
}

/// 自检用：把一组合成的触点帧喂给识别器。
///
/// 「触摸板手势不触发」要拆成两个独立问题：
///   ① 硬件有没有把触点送进来（引擎收到的帧数）
///   ② 收到之后认不认得出（识别器的判断）
/// 这个入口只管 ②：绕开硬件，直接喂合成数据，
/// 于是"识别逻辑写错了"和"系统没送帧"不会再互相背锅。
enum TrackpadSelfTest {
    /// - Parameters:
    ///   - frames: 每帧的手指数与触点坐标（归一化）
    ///   - modifiers: 所有帧共用的修饰键
    ///   - modifiersPerFrame: 逐帧的修饰键。给了就按帧取，
    ///     用来验证「起手判一次」——后面的帧不许覆盖起手时读到的修饰键。
    static func recognize(_ frames: [(fingers: Int, points: [CGPoint])],
                          modifiers: Set<ModifierKey> = [],
                          modifiersPerFrame: [Set<ModifierKey>]? = nil) -> TrackpadReport? {
        let recognizer = TrackpadRecognizer()
        var report: TrackpadReport?
        for (index, frame) in frames.enumerated() {
            let stamp = Double(index) * 0.05
            let frameModifiers = modifiersPerFrame?[safe: index] ?? modifiers
            if let result = recognizer.update(fingers: frame.fingers,
                                              touches: frame.points,
                                              timestamp: stamp,
                                              modifiers: frameModifiers) {
                report = result
            }
        }
        if report == nil { report = recognizer.finish() }
        return report
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 动态加载的 MultitouchSupport
///
/// 头文件（calftrail/TouchSynthesis 的 MultitouchSupport.h，2024 年还在维护）里能查到的：
///   MTDeviceCreateDefault()      —— 拿到**默认设备**（内置触控板），Create 规则，调用方持有
///   MTDeviceCreateList()         —— 列出全部设备，Create 规则，**数组持有**每个设备
///   MTRegisterContactFrameCallback(device, cb)
///   MTDeviceStart(device, int) / MTDeviceStop / MTDeviceRelease
///   MTDeviceIsAvailable() / MTDeviceIsBuiltIn(device)
///
/// 🔴 **两套取设备的语义不一样，这是以前收不到帧的根因**：
///   · `MTDeviceCreateList()` 在头文件里被标注成 "test"，返回的数组持有设备，
///     拿到的指针是**未 retain** 的。
///   · `MTDeviceCreateDefault()` 才是"能用的那个设备"，而且调用方持有引用。
/// 所以这里**以 default 为主、list 里 built-in 的为辅**，两个都试。
///
/// 🔴 **`MTDeviceStop` 只能对调用方自己持有的设备调用**。对 list 里那些
/// 别人（数组）持有的设备调用 → 过度释放 → 退出必崩。实测崩过四次，栈都一样：
///   MTDeviceStop → CFRelease / mt_DeviceUnregisterForHotplugNotifications → CFRunLoopSourceInvalidate
/// 现在的做法：**退出时什么都不停**。进程一死系统自己回收，没必要冒这个险。
private final class MTBridge {

    typealias DeviceListFn = @convention(c) () -> Unmanaged<CFArray>?
    // 头文件里的回调类型是 void 返回，我们原来写成 Int32，ABI 上一致但没必要冒险
    typealias ContactCallback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void
    typealias RegisterFn = @convention(c) (OpaquePointer, ContactCallback) -> Void
    typealias StartFn = @convention(c) (OpaquePointer, Int32) -> Void
    typealias StopFn = @convention(c) (OpaquePointer) -> Void
    typealias CreateDefaultFn = @convention(c) () -> OpaquePointer?
    typealias IsAvailableFn = @convention(c) () -> Bool
    typealias IsBuiltInFn = @convention(c) (OpaquePointer) -> Bool
    typealias GetDeviceIDFn = @convention(c) (OpaquePointer, UnsafeMutablePointer<UInt64>) -> Int32
    typealias GetFamilyIDFn = @convention(c) (OpaquePointer, UnsafeMutablePointer<Int32>) -> Int32
    typealias GetDriverTypeFn = @convention(c) (OpaquePointer, UnsafeMutablePointer<Int32>) -> Int32
    typealias NameFn = @convention(c) (OpaquePointer) -> Unmanaged<CFString>?

    private var handle: UnsafeMutableRawPointer?
    private var devices: [OpaquePointer] = []
    private var register: RegisterFn?
    private var startDevice: StartFn?
    private var stopDevice: StopFn?
    private var createDefault: CreateDefaultFn?
    private var isAvailable: IsAvailableFn?
    private var isBuiltIn: IsBuiltInFn?
    private var getDeviceID: GetDeviceIDFn?
    private var getFamilyID: GetFamilyIDFn?
    private var getDriverType: GetDriverTypeFn?
    private var copyName: NameFn?

    /// 找不到框架 / 一个设备都没有时，把原因留在 note 里给诊断看
    private(set) var note = ""

    /// 初始化失败时实例会被直接丢掉，note 跟着一起没了。
    /// 再存一份静态的，用来回答「点了启用为什么引擎没起来」。
    private(set) static var lastNote = ""

    /// 加载失败返回 nil，调用方据此把功能整体关掉
    init?() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW) else {
            note = "dlopen 失败：\(String(cString: dlerror()))"
            Self.lastNote = note
            return nil
        }
        guard let listSym = dlsym(handle, "MTDeviceCreateList"),
              let registerSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else {
            note = "缺符号（MTDeviceCreateList / MTRegisterContactFrameCallback / MTDeviceStart）"
            Self.lastNote = note
            dlclose(handle)
            return nil
        }

        self.handle = handle
        self.register = unsafeBitCast(registerSym, to: RegisterFn.self)
        self.startDevice = unsafeBitCast(startSym, to: StartFn.self)
        if let sym = dlsym(handle, "MTDeviceStop") {
            self.stopDevice = unsafeBitCast(sym, to: StopFn.self)
        }
        // 这几个是可选的：有就多一路信息，没有也不影响
        if let sym = dlsym(handle, "MTDeviceCreateDefault") {
            self.createDefault = unsafeBitCast(sym, to: CreateDefaultFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceIsAvailable") {
            self.isAvailable = unsafeBitCast(sym, to: IsAvailableFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceIsBuiltIn") {
            self.isBuiltIn = unsafeBitCast(sym, to: IsBuiltInFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceGetDeviceID") {
            self.getDeviceID = unsafeBitCast(sym, to: GetDeviceIDFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceGetFamilyID") {
            self.getFamilyID = unsafeBitCast(sym, to: GetFamilyIDFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceGetDriverType") {
            self.getDriverType = unsafeBitCast(sym, to: GetDriverTypeFn.self)
        }
        if let sym = dlsym(handle, "MTDeviceCopyDeviceName") {
            self.copyName = unsafeBitCast(sym, to: NameFn.self)
        }

        var found: [OpaquePointer] = []
        var descriptions: [String] = []

        // 🔴 按**设备号**去重，不能只比指针。
        // MTDeviceCreateDefault() 和 MTDeviceCreateList() 返回的是同一个触控板的
        // **两个不同指针**（实测 deviceID 完全一样）。只比指针就会把同一块板子收两次，
        // registerCallback 于是注册两遍 → 每个触点帧回调两次 → 时间间隔全成 0，
        // 识别结果跟着乱。
        var seenIDs: Set<UInt64> = []
        func identity(_ device: OpaquePointer) -> UInt64? {
            guard let getDeviceID else { return nil }
            var value: UInt64 = 0
            return getDeviceID(device, &value) == 0 ? value : nil
        }
        func alreadyHave(_ device: OpaquePointer) -> Bool {
            if found.contains(where: { $0 == device }) { return true }
            if let id = identity(device), seenIDs.contains(id) { return true }
            return false
        }
        func take(_ device: OpaquePointer, _ label: String) {
            guard !alreadyHave(device) else { return }
            if let id = identity(device) { seenIDs.insert(id) }
            found.append(device)
            descriptions.append(label)
        }

        // ① 首选：默认设备（内置触控板）
        if let createDefault, let device = createDefault() {
            take(device, "\(describe(device))（默认设备）")
        }

        // ② 兜底：列表里标着 built-in 的
        let createList = unsafeBitCast(listSym, to: DeviceListFn.self)
        if let listRef = createList()?.takeRetainedValue() {
            let count = CFArrayGetCount(listRef)
            for index in 0..<count {
                guard let raw = CFArrayGetValueAtIndex(listRef, index) else { continue }
                let device = OpaquePointer(raw)
                let builtIn = isBuiltIn?(device) ?? true
                guard builtIn else { continue }
                take(device, describe(device))
            }
        }

        guard !found.isEmpty else {
            let available = isAvailable.map { $0() } ?? false
            note = available ? "默认设备为空，列表里也没有内置设备" : "MTDeviceIsAvailable 返回 false（没有可用的触控板）"
            Self.lastNote = note
            return nil
        }

        devices = found
        note = "设备 \(found.count) 个：\(descriptions.joined(separator: "、"))"
    }

    /// 设备信息：名字 + 内置标记 + 设备号。给人看的，拿不到不影响功能。
    private func describe(_ device: OpaquePointer) -> String {
        var name = "未命名"
        if let copyName, let value = copyName(device)?.takeUnretainedValue() {
            name = value as String
        }
        var builtIn = ""
        if let isBuiltIn { builtIn = isBuiltIn(device) ? "（内置）" : "（外接）" }

        var idText = ""
        if let getDeviceID {
            var value: UInt64 = 0
            if getDeviceID(device, &value) == 0 { idText = " #\(value)" }
        }
        return "\(name)\(builtIn)\(idText)"
    }

    func registerCallback(_ callback: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void) {
        for device in devices {
            register?(device, callback)
            startDevice?(device, 0)
        }
    }

    /// 这个设备是不是我手上的。
    ///
    /// 重启引擎时旧设备停不掉（MTDeviceStop 会 use-after-free），
    /// 它的帧还在送。引擎靠这个把旧设备的帧认出来丢掉，
    /// 否则新旧两份帧一起进识别器，时间戳对不上，识别结果就是乱的。
    func owns(_ device: OpaquePointer) -> Bool {
        devices.contains { $0 == device }
    }

    /// 🔴 **不要调用 `MTDeviceStop`**。
    ///
    /// 列表里的设备由 `MTDeviceCreateList()` 返回的数组持有，我们拿到的是未 retain 的指针；
    /// `MTDeviceStop` 内部会释放它（还会在里面反注册 hotplug 通知）——
    /// 释放别人持有的对象就是 use-after-free，退出时必崩。实测崩了四次，栈都一样。
    ///
    /// 进程退出时系统会自己回收这些设备，没必要在退出前手动停。
    func stopDevices() {
        // 故意留空，见上面的说明
    }
}

/// 触摸板引擎：对外只暴露「能用吗」「识别到什么事了」
final class TrackpadEngine {

    /// 探测结果缓存。nil = 还没探测过。
    private static var availabilityCache: Bool?

    private var bridge: MTBridge?
    private var recognizer = TrackpadRecognizer()
    private(set) var isRunning = false

    /// 识别器被触控板线程和主线程的兜底定时器同时访问
    private let lock = NSLock()
    /// 最后一帧到达的时刻（墙钟）。兜底定时器据此判"手指已经抬起来了"
    private var lastFrameAt: Date = .distantPast
    /// 主线程兜底：收尾帧不一定来，靠它把轻点捞回来
    private var settleTimer: Timer?
    /// 收尾定时器是否已挂上。触控板线程每帧都会问，用小锁保护
    private let settleStateLock = NSLock()
    private var settleArmed = false
    /// 心跳定时器：定期记录"干等多久还没收到帧"
    private var heartbeatTimer: Timer?
    /// 心跳次数。启动后头几次会写进 trace 文件（回答「到底有没有收到帧」），之后就安静了。
    private var heartbeatTicks = 0

    /// 识别到手势时回调，**在主线程**。
    var onGesture: ((TrackpadReport) -> Void)?

    /// 单指起手（画轨迹的视觉反馈用）。参数是**起手那一刻**的修饰键，**在主线程**。
    var onTrailStart: ((Set<ModifierKey>) -> Void)?
    /// 单指轨迹点，**在主线程**。y 已翻成屏幕方向（向下为正），
    /// 坐标仍是触控板归一化单位（1.0 = 一条边），屏幕映射由调用方做。
    var onTrailPoint: ((CGPoint) -> Void)?
    /// 单指结束（抬手 / 超时）。**在主线程**。每一轮都会收到，不管有没有识别出手势。
    var onTrailEnd: (() -> Void)?

    /// 诊断计数（只在诊断模式下读）
    private(set) var frameCount = 0
    private(set) var lastFrameFingers = 0
    private(set) var lastPointSample: [CGPoint] = []
    /// 确认过的触点步长（Float 个数）。第一帧多指时自选，之后固定下来。
    private var confirmedStride: Int?
    /// 起手那一刻读到的修饰键。
    ///
    /// 🔴 用**独立的锁**：`onStart` 回调是在 `handleContactFrame` 持有 `lock` 的时候
    /// 触发的，这里再拿同一把锁就是死锁。
    private var lastStartModifiers: Set<ModifierKey> = []
    private let modifiersLock = NSLock()
    /// 引擎启动的时刻，用来算"已经干等了多少秒"
    private var startedAt: Date?

    /// 给界面看的实时诊断：收到多少帧、最后一帧几根指、干等了多久、
    /// 以及**起手那一刻读到的修饰键**。
    ///
    /// 最后这项是判断「配了 Fn 却匹配不上」的直接依据：
    /// 界面上一栏写着「起手修饰键：空」，就说明系统没把 Fn 报上来，
    /// 配了 Fn 的手势当然一条都命中不了。
    static var diagnostics: (frames: Int, fingers: Int, waiting: TimeInterval,
                             running: Bool, modifiers: Set<ModifierKey>) {
        guard let engine = TrackpadEngine.current else { return (0, 0, 0, false, []) }
        let waiting = engine.startedAt.map { Date().timeIntervalSince($0) } ?? 0
        engine.modifiersLock.lock()
        let modifiers = engine.lastStartModifiers
        engine.modifiersLock.unlock()
        return (engine.frameCount, engine.lastFrameFingers, waiting, engine.isRunning, modifiers)
    }

    /// C 回调需要拿到实例，用一个文件内的静态引用（fileprivate，同文件的全局回调可读）
    fileprivate static var current: TrackpadEngine?

    // MARK: - 落盘诊断
    //
    // "触摸板手势没反应"分不清是没收到帧还是没识别对。这里把每一轮的结果
    // 追加到 ~/Library/Application Support/BoxMouse/trackpad.log，
    // 用户摸几下之后看这个文件就知道断在哪一步。上限 200 行，超了从头写。

    private static var diagURL: URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("BoxMouse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trackpad.log")
    }

    // MARK: - 启停留痕
    //
    // 诊断日志（trackpad.log）只在面板可见时写——那是省 IO 的取舍。
    // 可用户报「勾了手势却没反应」的时候，面板往往关着，现场记录就没了。
    // 启停是「一次一行」的事件，单独留痕，不受面板开关影响。
    // 读这个文件就能分清三种情况：
    //   引擎没起来 / 起来了但一帧没收到 / 有帧但没识别对。

    private static var traceURL: URL? {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("BoxMouse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("trackpad-trace.log")
    }

    private static let traceLock = NSLock()
    private static var traceLines: [String] = []

    /// 引擎「该跑却没跑」的原因；空字符串 = 没失败。
    private(set) static var lastFailure = ""

    /// 追加一行留痕（只保留最后 60 行，永远不会长大）
    static func trace(_ text: String) {
        traceLock.lock()
        traceLines.append("\(stampFormatter.string(from: Date())) \(text)")
        if traceLines.count > 60 { traceLines.removeFirst(traceLines.count - 60) }
        let body = traceLines.joined(separator: "\n") + "\n"
        let url = traceURL
        traceLock.unlock()
        guard let url else { return }
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 该不该把「引擎没起来」告诉用户。
    ///
    /// 抽成纯函数是为了能被自检直接断：真起一次引擎要碰设备，自检不碰。
    /// 只有「确实需要它跑、它却没跑、而且有原因」才值得提示——
    /// 用户主动关掉引擎时不该弹任何东西。
    static func failureReport(needed: Bool, running: Bool, reason: String) -> String? {
        guard needed, !running, !reason.isEmpty else { return nil }
        return reason
    }

    private var diagLines: [String] = []
    /// 帧回调和主线程的定时器都会写，单独一把锁，别跟 recognizer 抢
    private let diagLock = NSLock()

    /// 诊断日志开关。
    ///
    /// 这是排查工具，不该在用户日常使用里每秒往磁盘写 10KB：
    /// 只有权限页的「触摸板自检」可见时才打开（见 TrackpadLiveCheck）。
    /// 关着的时候连字符串都不拼。
    private let diagEnabledLock = NSLock()
    private var diagEnabled = false

    private var isDiagEnabled: Bool {
        diagEnabledLock.lock()
        defer { diagEnabledLock.unlock() }
        return diagEnabled
    }

    /// 界面希望开着的诊断日志（诊断面板可见时）。
    /// 引擎可能是停的（没有启用的触摸板手势），这时先记下意愿，
    /// 等 start() 起来再应用。
    private static var loggingWanted = false

    /// 由界面调用：诊断面板出现/消失时开关
    static func setLogging(_ on: Bool) {
        loggingWanted = on
        current?.setLogging(on)
    }

    private func setLogging(_ on: Bool) {
        diagEnabledLock.lock()
        let changed = diagEnabled != on
        if changed { diagEnabled = on }
        diagEnabledLock.unlock()
        guard changed, on else { return }

        // 打开时从干净的一页开始：用户看到的第一行就是当前状态，
        // 不用在一屏历史里翻
        diagLock.lock()
        diagLines = []
        diagLock.unlock()
        appendDiag("=== 诊断开始（引擎\(isRunning ? "运行中" : "未运行")，已收到 \(frameCount) 帧）===")
    }

    private func appendDiag(_ line: String) {
        guard isDiagEnabled else { return }
        let stamp = Self.stampFormatter.string(from: Date())
        diagLock.lock()
        defer { diagLock.unlock() }
        diagLines.append("\(stamp) \(line)")
        if diagLines.count > 200 { diagLines.removeFirst(diagLines.count - 200) }
        guard let url = Self.diagURL else { return }
        let text = diagLines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// 本机能不能用触摸板手势（私有框架能加载 + 至少一个设备）
    static var isAvailable: Bool {
        if let cached = availabilityCache { return cached }
        // 🔴 **不许在这里 dlopen**。
        // 权限页一渲染就会问这个（用来决定要不要显示「输入监控」卡片），
        // 以前真去构造 MTBridge，等于「用户从没用过触摸板手势，
        // 但只要打开过权限页就把私有框架载进内存」——省资源就成了空话。
        //
        // 🔴 但也不能只查文件在不在！macOS 11 起系统库全在 dyld 共享缓存里，
        // 磁盘上根本没有这个文件，fileExists 会一律返回 false
        // —— 那等于把触摸板引擎永久关死（1.0.16 的 bug：
        //    引擎"启动成功"变成"永远起不来"，用户只看到手势无效）。
        // 正解：先查文件，查不到再问 dyld「共享缓存里有没有这个路径」，
        // 两个都不加载任何东西。
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        var ok = FileManager.default.fileExists(atPath: path)
        if !ok, let fn = sharedCacheContainsPath {
            ok = path.withCString { fn($0) }
        }
        availabilityCache = ok
        return ok
    }

    /// dyld 的 `_dyld_shared_cache_contains_path`。
    /// 用 dlsym 现取而不是链接期依赖：这个符号是私有 SPI，缺了要能优雅退化。
    private static let sharedCacheContainsPath: (@convention(c) (UnsafePointer<CChar>) -> Bool)? = {
        // RTLD_DEFAULT == (void *)-2
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                             "_dyld_shared_cache_contains_path") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (UnsafePointer<CChar>) -> Bool).self)
    }()

    /// 诊断用：为什么不可用
    static var unavailabilityReason: String {
        MTBridge()?.note ?? "未知"
    }

    /// 返回是否真的跑起来了。
    ///
    /// 以前这里是静默 return：用户勾了手势、引擎起不来，界面一句提示都没有，
    /// 表现就是「手势无效」，而且连个线索都没留下。现在每一处失败都留痕 + 回传原因。
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        guard TrackpadEngine.isAvailable else {
            Self.lastFailure = "私有框架不存在（MultitouchSupport）"
            Self.trace("start 失败：\(Self.lastFailure)")
            return false
        }

        if bridge == nil {
            guard let bridge = MTBridge() else {
                Self.lastFailure = MTBridge.lastNote.isEmpty ? "触控板设备初始化失败" : MTBridge.lastNote
                Self.trace("start 失败：\(Self.lastFailure)")
                return false
            }
            self.bridge = bridge
        }
        guard let bridge else {
            Self.lastFailure = "触控板设备初始化失败"
            Self.trace("start 失败：\(Self.lastFailure)")
            return false
        }

        TrackpadEngine.current = self
        startedAt = Date()
        diagLock.lock(); diagLines = []; diagLock.unlock()
        bridge.registerCallback(trackpadContactCallback)
        // 起手瞬间把修饰键写进日志：这是「配了 Fn 却读不到」这类问题的唯一证据。
        recognizer.onStart = { [weak self] mods in
            guard let self else { return }
            self.modifiersLock.lock()
            self.lastStartModifiers = mods
            self.modifiersLock.unlock()
            let text = mods.isEmpty ? "（空：什么修饰键都没按住）" : ModifierKey.describe(mods)
            self.appendDiag("起手：修饰键 \(text)")
        }
        isRunning = true
        // 面板正开着（或刚要开）就把日志接上
        if Self.loggingWanted { setLogging(true) }
        // 把两项授权一起写进去：设备列得出来、引擎也说启动成功，但一个触点帧都收不到，
        // 这个组合只可能是「输入监控」没给。日志里带上就能一句话判死，不用再猜。
        appendDiag("start ok（\(bridge.note)，输入监控 \(Permissions.hasInputMonitoring ? "已授权" : "未授权")，辅助功能 \(Permissions.hasAccessibility ? "已授权" : "未授权")）")
        // TCC 的答复在进程刚起来那一拍还没到，首行读到的是"未问过"，
        // 直接拿它下结论会把"刚启动"误判成"没授权"。晚一拍补一行，那行才是准的。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.isRunning else { return }
            self.appendDiag("auth → 输入监控 \(Permissions.hasInputMonitoring ? "已授权" : "未授权")，"
                            + "辅助功能 \(Permissions.hasAccessibility ? "已授权" : "未授权")")
        }
        // 收尾定时器不在这里挂：等真的有触点帧进来再挂（见 ensureSettleTimer）
        stopSettleTimer()
        Self.lastFailure = ""
        Self.trace("start ok：\(bridge.note)，输入监控 \(Permissions.hasInputMonitoring ? "已授权" : "未授权")，辅助功能 \(Permissions.hasAccessibility ? "已授权" : "未授权")")
        startHeartbeat()
        return true
    }

    /// 按需启停。
    ///
    /// 只有「总开关开着 + 至少一条启用的触摸板手势」时才值得挂着
    /// MultitouchSupport 的设备和回调。绝大多数人根本不用触摸板手势，
    /// 一直挂着就是白占内存、白开设备、白跑定时器。
    ///
    /// 不用在这里判 isAvailable：start() 自己会 guard，而且那一步会
    /// dlopen 私有框架——不该为了"决定要不要跑"先把库加载进来。
    /// 该不该跑：总开关开着 + 至少一条启用的触摸板手势。
    ///
    /// 抽成静态纯函数是为了能被自检直接断（引擎实例带设备，不能随便造）。
    static func shouldRun(engineEnabled: Bool, gestures: [Gesture]) -> Bool {
        engineEnabled && gestures.contains { $0.kind == .trackpad && $0.enabled }
    }

    func sync(shouldRun: Bool) {
        if shouldRun {
            if !isRunning { start() }
        } else if isRunning {
            stop()
        }
    }

    func stop() {
        stopSettleTimer()
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        bridge?.stopDevices()
        // 🔴 不调用 MTDeviceStop（use-after-free，见 MTBridge.stopDevices 的说明），
        // 但「重启引擎」必须**真的重启**：同一个设备再走一遍 register + start，
        // 等于没重启，设备还是原来那个状态。
        // 所以这里把 bridge 整个丢掉——Swift 侧不再持有这些裸指针，
        // 设备本身交给系统在进程退出时回收；下次 start 会重建一整套全新设备实例。
        // MTBridge 没有 deinit、也不会 dlclose 这个库，所以丢掉引用不会出事。
        bridge = nil
        isRunning = false
        TrackpadEngine.current = nil
        Self.trace("stop（不再需要：没有启用的触摸板手势，或总开关已关）")
    }

    /// 心跳：一台机器上"引擎在跑但一个帧都没有"是最难查的一种故障。
    /// 每 5 秒在日志里留一行"已等待 N 秒，收到帧 M"，用户摸一下触控板，
    /// 日志里立刻能看出帧数是 0 还是涨了——0 就是没收到，不是识别不对。
    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTicks = 0
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else { return }
            let frames = self.frameCount
            let waited = self.startedAt.map { Int(Date().timeIntervalSince($0)) } ?? 0
            // 启动后头 15 秒，有没有帧都留一行到 trace 文件。
            // 「勾了手势没反应」的现场往往关着诊断面板，这几行是唯一能回答
            // 「引擎起来了但一帧没收到（权限）」还是「有帧但没识别对」的证据。
            if self.heartbeatTicks < 3 {
                self.heartbeatTicks += 1
                Self.trace("心跳 \(waited)s：已收帧 \(frames)")
            }
            guard frames == 0 else { return }
            self.appendDiag("心跳：已等待 \(waited) 秒，仍未收到任何触点帧")
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    /// 🔴 收尾帧不一定来。手指全抬起来以后如果没有新的触点帧，
    /// 识别器就一直「active」，轻点永远等不到结果。
    /// 这里按「多久没来新帧」判结束，间隔取 90ms（轻点阈值 400ms，够密）。
    private func startSettleTimer() {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: 0.09, repeats: true) { [weak self] _ in
            self?.settleIfStale()
        }
        // .common 才能在拖动/滚动等 tracking 模式下继续跑
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// 有触点帧进来才挂收尾定时器。
    ///
    /// 常驻 11Hz 是纯白唤醒：一整天不碰触控板也要每秒醒 11 次取锁判空。
    /// 手指落下 → 挂上；这一轮收尾 → 摘掉。
    private func ensureSettleTimer() {
        settleStateLock.lock()
        let needStart = !settleArmed
        if needStart { settleArmed = true }
        settleStateLock.unlock()
        guard needStart else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.startSettleTimer()
        }
    }

    private func stopSettleTimer() {
        settleTimer?.invalidate()
        settleTimer = nil
        settleStateLock.lock()
        settleArmed = false
        settleStateLock.unlock()
    }

    private func settleIfStale() {
        lock.lock()
        let stale = recognizer.isActive && Date().timeIntervalSince(lastFrameAt) > 0.12
        let report = stale ? recognizer.finish() : nil
        if stale { recognizer.reset() }
        lock.unlock()

        // 这一轮结束了：收掉浮层，同时把定时器摘掉（等下次有帧再挂）
        if stale {
            stopSettleTimer()
            DispatchQueue.main.async { [weak self] in
                self?.onTrailEnd?()
            }
        }

        if let report {
            appendDiag("round → \(describe(report.event)) 手指 \(report.fingers) "
                       + "修饰键 \(ModifierKey.describe(report.modifiers))")
            onGesture?(report)
        }
    }

    private func describe(_ event: TrackpadEvent) -> String {
        switch event {
        case let .tap(f):              return "轻点(\(f))"
        case let .swipe(f, direction): return "滑动(\(f))\(direction.shortName)"
        case let .pinch(ratio):        return "捏合(\(String(format: "%.2f", ratio)))"
        case .path:                    return "画轨迹"
        }
    }

    /// 这个设备属于当前这一代 bridge 吗？不属于说明是重启前留下的旧设备，帧要丢掉。
    private func accepts(_ device: OpaquePointer) -> Bool {
        bridge?.owns(device) ?? false
    }

    fileprivate func handleContactFrame(device: OpaquePointer?,
                                        data: UnsafeMutableRawPointer?,
                                        count: Int32,
                                        timestamp: Double) {
        // 旧设备的帧要丢掉。
        //
        // 重启引擎时旧设备**不能**停（MTDeviceStop 会 use-after-free），
        // 它的 run loop source 还挂着，帧照样会送进来。不挡的话新旧两份帧
        // 一起进识别器，帧数翻倍、时间戳对不上，看起来就像"识别乱七八糟"。
        if let device, !accepts(device) { return }

        // 触点坐标只做合理性校验：不同系统版本给过 0…1 和 -1…1 两套原点，
        // 卡 0…1 会把一半以上的点丢掉，滑动就永远不够位移。
        var touches: [CGPoint] = []
        var usedStride = MTLayout.fallbackStride
        var rawDump: String?

        if let data, count > 0 {
            let base = data.assumingMemoryBound(to: Float.self)
            // 步长自适应：哪一套能让**所有**触点的坐标都合理，就用哪一套。
            // 只有一根手指时无从判断（第一根在三种步长下读到的都一样），
            // 这时用上一次确认过的步长，没有就用默认值。
            let candidates = confirmedStride.map { [$0] } ?? MTLayout.candidateStrides
            for stride in candidates {
                let points = readTouches(base: base, count: Int(count), stride: stride)
                guard points.count == Int(count) else { continue }
                touches = points
                usedStride = stride
                break
            }
            // 第一帧把原始字节打出来，结构体对不对一看便知
            if frameCount == 0 {
                rawDump = Self.hexDump(base, floats: min(Int(count) * usedStride + 12, 64))
            }
        }

        // 修饰键改用实时监听来读。
        //
        // 🔴 之前这里是 `CGEventSource.flagsState(.combinedSessionState)`，
        // 对 Fn（地球仪键）不一定读得到。而候选匹配是**全等**：
        // 配置 {fn}、实测 {} → 一个候选都匹配不上 → 「触摸板操作无效」。
        // ModifierWatch 做了三层兜底（flagsState / keyState / 事件流）。
        let modifiers = ModifierWatch.shared.current()

        if count > 0 { ensureSettleTimer() }

        lock.lock()
        if frameCount == 0 { Self.trace("收到第一帧：触点回调通了") }
        frameCount += 1
        lastFrameFingers = Int(count)
        lastFrameAt = Date()
        lastPointSample = touches
        if touches.count == Int(count) { confirmedStride = usedStride }
        let wasActive = recognizer.isActive
        let report = recognizer.update(fingers: Int(count),
                                       touches: touches,
                                       timestamp: timestamp,
                                       modifiers: modifiers)
        let started = !wasActive && recognizer.isActive && Int(count) == 1
        let frameNote = frameCount % 60 == 1
            ? "frame #\(frameCount) 手指 \(Int(count)) 触点 \(touches.count) 步长 \(usedStride)"
            : nil
        lock.unlock()

        if let frameNote { appendDiag(frameNote) }
        if let rawDump { appendDiag("首帧原始数据：\(rawDump)") }

        // 画轨迹的视觉反馈：只跟单指。起手时把修饰键带出去，
        // 由调用方决定这一轮要不要画（没配画轨迹手势就不画，免得指针移动时一直拖线）。
        if started {
            let startModifiers = modifiers
            DispatchQueue.main.async { [weak self] in
                self?.onTrailStart?(startModifiers)
            }
        }
        if Int(count) == 1, let first = touches.first {
            let flipped = CGPoint(x: first.x, y: -first.y)
            DispatchQueue.main.async { [weak self] in
                self?.onTrailPoint?(flipped)
            }
        }
        if count <= 0 {
            DispatchQueue.main.async { [weak self] in
                self?.onTrailEnd?()
            }
        }

        if let report {
            DispatchQueue.main.async { [weak self] in
                self?.onGesture?(report)
            }
        }
    }

    /// 按给定步长读一组触点。**任何一根不合法就整组作废**——
    /// 宁可这一帧没坐标，也不能拿半真半假的数据去判方向。
    private func readTouches(base: UnsafePointer<Float>, count: Int, stride: Int) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let offset = index * stride
            let x = base[offset + MTLayout.normalizedX]
            let y = base[offset + MTLayout.normalizedY]
            guard x.isFinite, y.isFinite,
                  abs(Double(x)) <= MTLayout.maxAbs, abs(Double(y)) <= MTLayout.maxAbs else {
                return []
            }
            result.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
        }
        return result
    }

    /// 首帧的十六进制转储，用来看结构体到底长什么样
    private static func hexDump(_ base: UnsafePointer<Float>, floats count: Int) -> String {
        var parts: [String] = []
        for index in 0..<count {
            let value = base[index]
            if value.isFinite {
                parts.append(String(format: "%.3f", value))
            } else {
                parts.append("nan")
            }
        }
        return parts.joined(separator: " ")
    }
}

/// C 回调必须是无捕获的全局量
private let trackpadContactCallback: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void = {
    device, data, count, timestamp, _ in
    TrackpadEngine.current?.handleContactFrame(device: device, data: data, count: count, timestamp: timestamp)
}

// ============================================================
// 诊断：把触摸板的原始帧采集成一份报告
//
// "触摸板手势不触发"可能断在四个地方：框架加载、设备启动、收到帧、
// 识别出结果。光看界面分不清是哪一步，所以这里把四段都打出来：
//   BoxMouse --trackpad-probe 20   然后去触控板上做几次手势
// ============================================================

enum TrackpadProbe {
    static func run(seconds: Double) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var lines: [String] = []
        // MultitouchSupport 走 IOHIDEventSystemClient，属于「输入监控」管辖。
        // 没这个权限时框架能加载、设备能列出来、就是不回帧 ——
        // 症状和"手势无效"一模一样，所以一定要先把它打出来。
        lines.append("输入监控（ListenEvent）已授权：\(CGPreflightListenEventAccess())")
        lines.append("辅助功能（Accessibility）已授权：\(AXIsProcessTrusted())")
        lines.append("MultitouchSupport 可用：\(TrackpadEngine.isAvailable)")
        lines.append("说明：\(TrackpadEngine.unavailabilityReason)")

        let engine = TrackpadEngine()
        engine.onGesture = { report in
            lines.append("识别到手势：\(report.event)（手指 \(report.fingers)，修饰键 \(ModifierKey.describe(report.modifiers))）")
        }
        engine.start()
        lines.append("引擎已启动：\(engine.isRunning)")
        lines.append("请在这 \(Int(seconds)) 秒内到触控板上做几次手势…")

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            lines.append("收到的触点帧数：\(engine.frameCount)")
            lines.append("最后一帧手指数：\(engine.lastFrameFingers)")
            let sample = engine.lastPointSample.prefix(3)
                .map { "(\(String(format: "%.3f", $0.x)), \(String(format: "%.3f", $0.y)))" }
                .joined(separator: " ")
            lines.append("最后触点样本：\(sample.isEmpty ? "无" : sample)")
            engine.stop()

            let text = lines.joined(separator: "\n")
            try? text.write(toFile: "/tmp/boxmouse-trackpad.txt", atomically: true, encoding: .utf8)
            print(text)
            app.terminate(nil)
        }

        app.run()
    }
}
