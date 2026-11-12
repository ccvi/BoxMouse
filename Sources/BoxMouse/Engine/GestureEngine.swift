import AppKit
import CoreGraphics

// ============================================================
// 手势引擎：CGEventTap 的安装与状态机
//
// 三条硬规则（踩过就知道疼）：
//
// 1) **没认出任何手势时必须把事件原样放行。**
//    吞掉右键会让所有应用的右键菜单失效——这是这类工具最容易造成
//    "装完就后悔"的故障。所以起手前先算一遍候选，空集就直接 return 原事件。
//    修饰键也算在候选条件里：只建了「⌘ + 右键画 L」时，裸右键照样能弹菜单。
//
// 2) **短距离拖拽要当点击重放。**
//    右键按下→抖动几像素→松开，用户的本意是"右键单击"。我们已经在
//    down 时把事件吞了，就必须自己补发一次完整的 down/up，否则菜单再也不弹。
//
// 3) **修饰键只在起手那一刻判一次。**
//    起手时事件带什么修饰键就按那套候选走，中途再按/松修饰键不改判定，
//    否则用户画到一半松开 ⌘ 就会突然换成另一条手势。收手时也用起手时记下的集合。
// ============================================================

private struct DrawState {
    var trigger: GestureTrigger
    /// 起手瞬间按住的修饰键（空集 = 无）
    var modifiers: Set<ModifierKey>
    var points: [CGPoint]
    var start: CGPoint
    var buttonNumber: Int64
    var context: TargetContext
}

@MainActor
final class GestureEngine {

    private let store: GestureStore
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var draw: DrawState?
    private let overlay = TrailOverlay()
    /// 浮层是否已经真正显示（延迟到开始画才创建，见 append）
    private var trailVisible = false

    /// 供界面显示「引擎当前是否真的在监听」
    private(set) var isRunning = false

    /// 键盘监听是否挂上了。
    ///
    /// 键盘事件需要「输入监控」授权，而鼠标事件只要「辅助功能」。没给输入监控时
    /// tapCreate 会连鼠标一起失败——退化成只监听鼠标，至少保住主功能，
    /// 并且要能让界面说清"快捷键为什么不灵"。
    private(set) var keyboardTapAvailable = true

    /// 平滑滚轮：把离散滚轮的行滚动摊成逐帧像素滚动
    private let scroller = SmoothScroller()
    /// 按下被当成「执行动作」吞掉的侧键编号，等对应的 up 到来时也要吞掉
    private var swallowedSideButtons: Set<Int64> = []

    /// 一轮手势的结局。鼠标手势和触摸板手势走同一套，界面据此弹提示。
    enum FireOutcome: Equatable {
        /// 认出来了，动作也发出去了
        case matched(Gesture)
        /// 认出来了，但动作没执行成功（比如窗口已经不在、应用被删了）
        case failed(Gesture)
        /// 画了，但不像任何一条
        case unmatched
    }

    /// 每轮手势结束回调一次。不直接发布状态：引擎是纯逻辑对象，
    /// 界面订阅（以及要不要弹提示）由 AppModel 负责。
    var onResult: ((FireOutcome) -> Void)?

    init(store: GestureStore) {
        self.store = store
    }

    // MARK: - 生命周期

    func sync() {
        // 判据是 needsEventTap 而不是 engineEnabled：平滑滚轮、反方向、侧键动作
        // 都是独立于「手势引擎」总开关的，用户完全可以关掉手势只用滚轮增强。
        if store.settings.needsEventTap && Permissions.hasAccessibility {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard tap == nil else { return }
        guard Permissions.hasAccessibility else {
            isRunning = false
            return
        }

        // 只监听鼠标键 + 键盘按下（跑快捷键）。修饰键（flagsChanged）和 pointer
        // 移动（mouseMoved）不再需要：修饰键改成起手时读事件自带的 flags，
        // 鼠标移动只在新手势起手后才追加。少挂高频事件，对输入延迟更友好。
        var types: [CGEventType] = [
            .rightMouseDown, .rightMouseDragged, .rightMouseUp,
            .otherMouseDown, .otherMouseDragged, .otherMouseUp,
            // 滚轮：平滑滚轮和反方向都要拦。触控板滚动量很大，但回调里
            // 只是读几个整数、两个开关都没开就立刻放行，开销可以忽略。
            .scrollWheel,
            // 快捷键条目要匹配全局按键。键盘事件量远小于 pointer 移动，
            // 而且先查"有没有配快捷键"，没有就直接放行，不会给打字增加延迟。
            .keyDown
        ]

        var created = makeTap(types)
        var keyboard = true
        if created == nil, types.contains(.keyDown) {
            // 键盘 tap 要「输入监控」。没授权时整只 tap 都建不起来，
            // 会连鼠标手势一起废掉——退化成只监听鼠标，先保住主功能。
            types.removeAll { $0 == .keyDown }
            created = makeTap(types)
            keyboard = false
        }
        guard let created else {
            isRunning = false
            keyboardTapAvailable = false
            return
        }
        keyboardTapAvailable = keyboard

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)

        self.tap = created
        self.runLoopSource = source
        self.isRunning = true
    }

    private func makeTap(_ types: [CGEventType]) -> CFMachPort? {
        var mask: CGEventMask = 0
        for type in types {
            mask |= (1 << type.rawValue)
        }
        return CGEvent.tapCreate(tap: .cgSessionEventTap,
                                 place: .headInsertEventTap,
                                 options: .defaultTap,
                                 eventsOfInterest: mask,
                                 callback: gestureTapCallback,
                                 userInfo: Unmanaged.passUnretained(self).toOpaque())
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
        // 停表时滚轮还有没摊完的余量，必须清掉：不然用户关掉开关之后
        // 屏幕还会自己再滚一小段，看起来像"开关没生效"。
        scroller.reset()
        swallowedSideButtons.removeAll()
        cancel()
    }

    // MARK: - 事件处理

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let passthrough = Unmanaged<CGEvent>.passUnretained(event)

        // 🔴 自己重放的事件必须放行，否则死循环：
        // 短点击 → finish() → replayClick 补发 down/up → 事件流经 session tap
        // （我们挂在最上游）→ 又被自己吞掉 → 又判定成短点击 → 又重放……
        // 表现就是：点击点红点狂闪、鼠标卡到没法用，直到 tap 回调超时被系统禁用。
        // 重放时打了 eventSourceUserData 标记（见 replayClick），见到标记直接放行。
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMark {
            return passthrough
        }

        // 系统会因回调超时/用户输入临时禁用 tap，必须自己开回来，
        // 否则手势会"安静地"失效——不报错、不弹窗，最难查。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return passthrough
        }

        // 滚轮和侧键动作有各自的开关，**不受「手势引擎」总开关管**：
        // 用户可能只想用平滑滚轮、不想让任何手势生效。
        if type == .scrollWheel {
            return handleScroll(event) ? nil : passthrough
        }
        if type == .otherMouseDown {
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            if (number == 3 || number == 4), handleSideButtonAction(number: number, event: event) {
                return nil
            }
        }
        if type == .otherMouseUp {
            // 按下被我们执行成动作了，松开也必须吞掉：否则应用收到一个
            // 没有 down 的 up，某些应用会把它当独立点击处理。
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            if swallowedSideButtons.remove(number) != nil { return nil }
        }

        guard store.settings.engineEnabled else { return passthrough }

        switch type {
        case .rightMouseDown:
            return begin(trigger: .rightButton, buttonNumber: 1, event: event) ? nil : passthrough

        case .otherMouseDown:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            let trigger: GestureTrigger = number == 2 ? .middleButton : .sideButton
            return begin(trigger: trigger, buttonNumber: number, event: event) ? nil : passthrough

        case .rightMouseDragged, .otherMouseDragged:
            guard draw != nil else { return passthrough }
            append(event.location)
            return nil

        case .rightMouseUp:
            // 必须同一颗键松开才算画完：中键手势期间顺手点一下右键，
            // 不该把正在画的中键手势提前收掉。
            guard let state = draw, state.buttonNumber == 1 else {
                return passthrough
            }
            finish()
            return nil

        case .otherMouseUp:
            let number = event.getIntegerValueField(.mouseEventButtonNumber)
            guard let state = draw, state.buttonNumber == number else {
                return passthrough
            }
            finish()
            return nil

        case .keyDown:
            return handleKeyDown(event) ? nil : passthrough

        default:
            return passthrough
        }
    }

    /// 键盘按键 → 快捷键条目。
    ///
    /// 返回 true 表示"这条事件归我们了"，调用方会把事件吞掉，不再传给当前应用——
    /// 全局快捷键本来就该独占，不然按完还会往输入框里打出一个字符。
    private func handleKeyDown(_ event: CGEvent) -> Bool {
        guard store.settings.engineEnabled else { return false }
        // 编辑器正在录制组合键：这一下是"给我听"，不是"给我执行"
        guard !ShortcutCapture.isRecording else { return false }
        // 长按会连发 keyDown，只认第一次
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return false }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let front = NSWorkspace.shared.frontmostApplication

        guard let gesture = store.shortcutMatch(keyCode: keyCode,
                                                flags: event.flags,
                                                bundleID: front?.bundleIdentifier) else {
            return false
        }

        // 快捷键作用于"当前正在用的应用"，没有起手窗口这回事
        let context = TargetContext(bundleID: front?.bundleIdentifier,
                                    pid: front?.processIdentifier,
                                    window: nil)
        let didRun = ActionRunner.shared.perform(gesture.action, context: context)
        onResult?(didRun ? .matched(gesture) : .failed(gesture))
        return true
    }

    // MARK: - 滚轮

    /// 滚轮事件：只做两件事——反方向、把离散滚轮摊成像素滚动。
    ///
    /// 返回 true 表示"这条事件归我们了"，调用方吞掉它。
    ///
    /// 🔴 触控板 / 妙控鼠标（`IsContinuous = 1`）**不做平滑**：系统已经给过
    /// 平滑和惯性，再来一遍就是双重缓动，手感会发飘。它们只处理反方向。
    private func handleScroll(_ event: CGEvent) -> Bool {
        guard store.settings.mouseControlEnabled else { return false }
        let smooth = store.settings.smoothScrollEnabled
        let invert = store.settings.invertScrollEnabled
        let boost = Self.boostMultiplier(boostKey: store.settings.scrollBoostKey,
                                         flags: event.flags)
        guard smooth || invert || boost != 1.0 else { return false }

        let isContinuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0

        if isContinuous || !smooth {
            guard invert || boost != 1.0 else { return false }
            // 原地改完放行：保留 phase / momentumPhase，触控板的惯性不会被切断。
            // 先缩再翻（乘法可交换），两件事合成一次字段遍历。
            Self.scaleScrollFields(event, by: boost)
            if invert { Self.flipScrollFields(event) }
            return false
        }

        // 离散滚轮 + 开了平滑
        var dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        var dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        if dx == 0, dy == 0 {
            // 有的鼠标只给行数，换算成像素
            dx = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)) * SmoothScroller.baseLineHeight
            dy = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)) * SmoothScroller.baseLineHeight
        }
        if invert { dx = -dx; dy = -dy }
        dx *= boost
        dy *= boost
        guard dx != 0 || dy != 0 else { return false }

        let strength = min(3.0, max(0.2, store.settings.smoothScrollStrength))
        scroller.feed(pixelsX: dx * strength, pixelsY: dy * strength,
                      duration: store.settings.smoothScrollDuration,
                      gain: store.settings.smoothScrollGain)
        return true
    }

    /// 把一条滚轮事件的位移方向翻过来。
    ///
    /// 🔴 这里有三个 delta 视图：`PointDelta`（像素）、`FixedPtDelta`（16.16 定点）
    /// 和 `Delta`（行）。**它们不是独立的**，实测（见自检）：
    ///
    /// - 写 `Delta` 会**联动重算** `PointDelta` 和 `FixedPtDelta`，而且换算带取整，
    ///   30 → 翻一次变 -24，再翻一次是 24 —— 不可逆，来回拨两次位移就缩水。
    ///   更糟的是触控板事件的 `Delta` 恒为 0，写它会把整条事件的像素位移
    ///   **清零**，反方向一开就等于滚不动。
    /// - 写 `PointDelta` / `FixedPtDelta` 只改自己，精确、可逆、互不牵连。
    ///
    /// 所以主路径只翻后两套；只有遇到「纯行滚动」的老式事件（像素位移为 0、
    /// 行位移非 0）才退回翻 `Delta`——那时 Pixel 本来就是 0，联动不会破坏什么。
    static func flipScrollFields(_ event: CGEvent) {
        let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)

        if pointX != 0 || pointY != 0 {
            if pointY != 0 {
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: -pointY)
            }
            if pointX != 0 {
                event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: -pointX)
            }
            let fixedY = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
            let fixedX = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
            if fixedY != 0 {
                event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixedY)
            }
            if fixedX != 0 {
                event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -fixedX)
            }
            return
        }

        let lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let lineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        if lineY != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: -lineY)
        }
        if lineX != 0 {
            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: -lineX)
        }
    }

    /// 按住「加速键」时位移乘多少。2 倍是手感折中：再大就变成"一按就飞"，长页面上
    /// 容易冲过头；嫌不够可以把速度增益一起调上去。
    static let scrollBoostFactor: Double = 2.0

    /// 加速键判定（纯函数，自检直接断）。
    ///
    /// 用的是**这条滚轮事件自带的 flags**，不是实时查键盘状态：滚轮事件一定有
    /// flags，读它最准；查键盘状态在 Fn 上本来就不可靠（同类问题在触摸板那边踩过）。
    static func boostMultiplier(boostKey: ModifierKey?, flags: CGEventFlags) -> Double {
        guard let boostKey, flags.contains(boostKey.flag) else { return 1.0 }
        return scrollBoostFactor
    }

    /// 把位移按倍率放大（放行路径用）。
    ///
    /// 只动 `PointDelta` / `FixedPtDelta`，绝不动 `Delta`——写 `Delta` 会联动重算
    /// 另外两套且不可逆，触控板上还会把位移清零（见 `flipScrollFields` 的说明）。
    /// `Delta` 不跟着缩的代价是：只读行位移的老应用拿不到加速，但它们本来也不参与
    /// 平滑，属于可接受的取舍。
    static func scaleScrollFields(_ event: CGEvent, by factor: Double) {
        guard factor != 1.0 else { return }
        let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        if pointY != 0 {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                                       value: Int64((Double(pointY) * factor).rounded()))
        }
        if pointX != 0 {
            event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2,
                                       value: Int64((Double(pointX) * factor).rounded()))
        }
        let fixedY = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let fixedX = event.getIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2)
        if fixedY != 0 {
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                       value: Int64((Double(fixedY) * factor).rounded()))
        }
        if fixedX != 0 {
            event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                       value: Int64((Double(fixedX) * factor).rounded()))
        }
    }

    // MARK: - 侧键

    /// 侧键（Forward / Back）按下即执行动作——**前提是这颗键配了动作**。
    ///
    /// 没配就返回 false，事件继续往下走老路径（按住侧键画轨迹），
    /// 所以不需要额外的「模式」开关：一颗键的行为由它自己有没有动作决定。
    ///
    /// buttonNumber 约定：**3 = Back、4 = Forward**，和浏览器、Edge / Chrome
    /// 的内置映射一致。个别鼠标厂商会反过来，真遇到再给「交换」开关。
    private func handleSideButtonAction(number: Int64, event: CGEvent) -> Bool {
        guard store.settings.mouseControlEnabled else { return false }
        let action = number == 4 ? store.settings.forwardButtonAction
                                 : store.settings.backButtonAction
        guard let action else { return false }

        let context = TargetResolver.resolve(mode: store.settings.targetMode,
                                             point: event.location,
                                             lockWindow: store.settings.lockWindow)
        let didRun = ActionRunner.shared.perform(action, context: context)
        // 侧键是"按了没反应最难查"的一类：面板上一切正常，实际可能连事件都没收到。
        // 留一行痕（trace 是 60 行环，不长大），出问题时能一眼看出走到了哪一步。
        TrackpadEngine.trace("侧键 \(number) → \(action.kind.displayName)"
                             + "，目标 \(context.bundleID ?? "nil")，"
                             + (didRun ? "执行成功" : "执行失败"))
        if didRun { swallowedSideButtons.insert(number) }
        return didRun
    }

    // MARK: - 起手 / 采集 / 收尾

    private func begin(trigger: GestureTrigger, buttonNumber: Int64, event: CGEvent) -> Bool {
        guard draw == nil else { return false }

        // 修饰键从这次 down 事件自带的 flags 里读：用户按住 Fn 再按右键时，
        // ⌘⌥⌃⇧fn 的状态已经在 flags 里了，不需要自己维护按键状态机。
        let modifiers = ModifierKey.set(from: event.flags)

        // 先解析目标应用：作用域可能让当前应用一条手势都没有，
        // 那就别吞事件（否则右键菜单直接废掉）。
        let point = event.location
        let context = TargetResolver.resolve(mode: store.settings.targetMode,
                                             point: point,
                                             lockWindow: store.settings.lockWindow)
        if store.settings.skipOwnWindow, context.bundleID == Bundle.main.bundleIdentifier {
            return false
        }
        let candidates = store.candidates(trigger: trigger,
                                          modifiers: modifiers,
                                          bundleID: context.bundleID)
        guard !candidates.isEmpty else { return false }

        draw = DrawState(trigger: trigger,
                         modifiers: modifiers,
                         points: [point],
                         start: point,
                         buttonNumber: buttonNumber,
                         context: context)

        // 浮层不在这里显示：右键单击（只点菜单）不该闪一下红点，
        // 等真的拖出轨迹再创建，见 append(_:)
        trailVisible = false
        return true
    }

    private func append(_ point: CGPoint) {
        guard var state = draw else { return }
        if let last = state.points.last,
           hypot(point.x - last.x, point.y - last.y) < 2 {
            return
        }
        state.points.append(point)
        draw = state

        // 🔴 浮层延迟到「真的开始画」才出现（离起点超过 6pt）。
        // 以前一按下就 show 一个直径 12pt 的大红圆点：右键单击点菜单也会闪一下，
        // 用户反馈"很突兀"。现在单击全程没有浮层，画起来的第一帧就是线段本身；
        // 顺带省掉单击时一次全屏窗口的创建与挂载。
        if !trailVisible {
            let travel = hypot(point.x - state.start.x, point.y - state.start.y)
            guard travel >= 6, store.settings.showTrail else { return }
            trailVisible = true
            overlay.show(at: state.start,
                         color: NSColor(hexString: store.settings.trailColorHex) ?? .systemRed,
                         width: store.settings.trailWidth)
            // 补上延迟期间已经走过的点，否则第一笔会从半截开始
            for pending in state.points.dropFirst() {
                overlay.append(pending)
            }
            return
        }
        overlay.append(point)
    }

    private func cancel() {
        draw = nil
        trailVisible = false
        overlay.hide()
    }

    private func finish() {
        guard let state = draw else { return }
        draw = nil
        trailVisible = false
        overlay.hide()

        let length = PathRecognizer.length(state.points)
        guard length >= store.settings.minPathLength else {
            // 当成一次普通点击重放：右键菜单、中键粘贴都还照常工作
            replayClick(state)
            return
        }

        let normalized = PathRecognizer.normalize(state.points)
        let candidates = store
            .candidates(trigger: state.trigger,
                        modifiers: state.modifiers,
                        bundleID: state.context.bundleID)
            .filter { !$0.path.isEmpty }
            .map { (gesture: $0, path: $0.path) }

        guard let match = PathRecognizer.bestMatch(path: normalized, candidates: candidates) else {
            onResult?(.unmatched)
            return
        }
        // 应用/分组作用域的手势：目标应用可能不在前台（指针压在它上面而已），
        // 键盘类动作必须先把它激活，否则 ⌘T 之类会打进当前前台应用。
        var context = state.context
        context.activatesTarget = TargetResolver.needsActivation(
            targetPID: context.pid,
            frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            scopeIsGlobal: store.scope(id: match.gesture.scopeID)?.kind == .global)
        let didRun = ActionRunner.shared.perform(match.gesture.action, context: context)
        onResult?(didRun ? .matched(match.gesture) : .failed(match.gesture))
    }

    /// 重放事件的标记值（"BM" = BoxMouse）。
    /// 写进 eventSourceUserData，tap 回调里见到它就知道是自己重放的，直接放行。
    /// 没有这个标记，重放事件会再进一次自己的 tap，短点击就变成死循环。
    ///
    /// `nonisolated`：平滑滚轮的派发在后台队列上（SmoothScroller），
    /// 那里读不到 MainActor 隔离的静态属性。
    nonisolated static let replayMark: Int64 = 0x424D

    /// 补发被我们吞掉的那次点击
    private func replayClick(_ state: DrawState) {
        let source = CGEventSource(stateID: .hidSystemState)
        let isRight = state.trigger == .rightButton
        let button: CGMouseButton = isRight ? .right : .center

        let down = CGEvent(mouseEventSource: source,
                           mouseType: isRight ? .rightMouseDown : .otherMouseDown,
                           mouseCursorPosition: state.start,
                           mouseButton: button)
        let up = CGEvent(mouseEventSource: source,
                         mouseType: isRight ? .rightMouseUp : .otherMouseUp,
                         mouseCursorPosition: state.start,
                         mouseButton: button)
        // other 事件必须显式带按键号（中键=2，侧键=3/4），否则系统当成第 0 号键
        down?.setIntegerValueField(.mouseEventButtonNumber, value: state.buttonNumber)
        up?.setIntegerValueField(.mouseEventButtonNumber, value: state.buttonNumber)
        // 修饰键要还原：用户按住 ⌘ 右键点击时，候选是「⌘ + 右键」那几条，
        // 重放出去的也是一次 ⌘ + 右键点击，语义才一致。
        var flags: CGEventFlags = []
        for modifier in state.modifiers { flags.insert(modifier.flag) }
        down?.flags = flags
        up?.flags = flags
        // 🔴 打上"自己人"标记：tap 回调里凭这个放行，见 handle() 的说明。
        // 没有它，这次 down/up 会再次被自己的 tap 吞掉——红点狂闪、鼠标卡死。
        down?.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
        up?.setIntegerValueField(.eventSourceUserData, value: Self.replayMark)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - C 回调桥

private func gestureTapCallback(proxy: CGEventTapProxy,
                                type: CGEventType,
                                event: CGEvent,
                                userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let engine = Unmanaged<GestureEngine>.fromOpaque(userInfo).takeUnretainedValue()
    // 回调跑在装 tap 的那个线程（主线程）的 run loop 上
    return MainActor.assumeIsolated {
        engine.handle(type: type, event: event)
    }
}
