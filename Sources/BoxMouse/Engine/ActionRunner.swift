import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

// ============================================================
// 动作执行 + 目标应用解析
//
// 这里所有能力都要辅助功能授权（Accessibility）。未授权时：
//   · 键盘/媒体键事件发得出去，但会被系统丢弃；
//   · AX 窗口操作直接返回失败，于是走键盘快捷键降级。
// 降级不是"凑合"——⌘W / ⌘M / ⌃⌘F 本来就是这些窗口操作的标准快捷键，
// 只是不如 AX 精准（AX 能锁定具体窗口，快捷键只能作用于当前焦点窗口）。
// ============================================================

/// 一次手势发生时的目标上下文
struct TargetContext {
    var bundleID: String?
    var pid: pid_t?
    /// 按键那一刻锁定的窗口（按需）
    var window: AXUIElement?
    /// 执行键盘类动作前，是否要先把目标应用激活。
    ///
    /// 🔴 合成的 ⌘ 组合键一定落在**当前前台**应用上，跟"作用域判定为哪个应用"无关。
    /// 指针压在 Edge 上、前台是别的应用时：作用域匹配到了「浏览器」那几条、
    /// 浮层也提示对了，但 ⌘T 打进了前台应用——用户看到的就是"提示对了却不起作用，
    /// 非得先点一下浏览器"。所以应用/分组作用域命中时，执行前先把目标应用激活。
    var activatesTarget: Bool = false
}

enum Permissions {

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 弹系统授权引导（只会弹一次，之后要用户自己去设置里开）
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 输入监控
    //
    // 触摸板手势走 MultitouchSupport，它读的是 IOHIDEventSystemClient，
    // 归「输入监控」管——**辅助功能给不了这一项**。
    // 没有它的时候表现极具迷惑性：框架能加载、设备能列出来、引擎"启动成功"，
    // 就是一个触点帧都收不到。所以单独查、单独申请。

    static var hasInputMonitoring: Bool {
        CGPreflightListenEventAccess()
    }

    /// 弹一次系统授权引导。用户点过之后就只剩手动去设置里开。
    @discardableResult
    static func requestInputMonitoring() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}

enum TargetResolver {

    /// 解析当前手势应当作用于哪个应用
    static func resolve(mode: TargetMode, point: CGPoint, lockWindow: Bool) -> TargetContext {
        var bundleID: String?
        var pid: pid_t?

        switch mode {
        case .frontmost:
            if let app = NSWorkspace.shared.frontmostApplication,
               app.bundleIdentifier != Bundle.main.bundleIdentifier {
                bundleID = app.bundleIdentifier
                pid = app.processIdentifier
            }
        case .underPointer:
            break
        }

        // 指针所在应用：顺带兜住「前台是 BoxMouse 自己」的情况
        if bundleID == nil,
           let element = element(at: point),
           let ownerPID = processID(of: element) {
            pid = ownerPID
            bundleID = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier
        }

        var window: AXUIElement?
        if let pid {
            // 指针模式：窗口也取**指针底下那一个**。
            // 后台应用的 AXFocusedWindow 通常是 nil，或者只是"它自己以为的焦点窗口"；
            // 用户指针明明压在另一个窗口上，动作却落到别处甚至直接失败。
            if mode == .underPointer {
                window = windowUnderPointer(point, pid: pid)
            }
            if window == nil, lockWindow {
                window = focusedWindow(pid: pid)
            }
        }
        return TargetContext(bundleID: bundleID, pid: pid, window: window)
    }

    /// 指针下那个元素所属的窗口。
    static func windowUnderPointer(_ point: CGPoint, pid: pid_t) -> AXUIElement? {
        guard let element = element(at: point),
              processID(of: element) == pid else { return nil }
        // 绝大多数元素直接带 kAXWindowAttribute
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success,
           let window = value {
            return (window as! AXUIElement)
        }
        // 退一步：沿 parent 链爬到 role == AXWindow 的那一层
        var current: AXUIElement? = element
        for _ in 0..<16 {
            guard let node = current else { return nil }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == (kAXWindowRole as String) {
                return node
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent else { return nil }
            current = (next as! AXUIElement)
        }
        return nil
    }

    /// 键盘类动作要不要先把目标应用激活。
    ///
    /// 只有「应用/分组作用域」命中时才激活：那说明用户明确就是要在那个应用里做事。
    /// 全局作用域的快捷键动作保持原样打给前台——指针只是恰好停在桌面上时，
    /// 不该把 Finder 拽到前台。
    static func needsActivation(targetPID: pid_t?, frontPID: pid_t?, scopeIsGlobal: Bool) -> Bool {
        guard let targetPID else { return false }
        guard targetPID != frontPID else { return false }
        return !scopeIsGlobal
    }

    static func element(at point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &element)
        return result == .success ? element : nil
    }

    /// 元素所属进程。AXAPI 没有 kAXPIDAttribute，只能直接问。
    static func processID(of element: AXUIElement) -> pid_t? {
        var value: pid_t = 0
        return AXUIElementGetPid(element, &value) == .success ? value : nil
    }

    static func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let window = value else { return nil }
        return (window as! AXUIElement)
    }

    /// 该进程里第一个处于最小化状态的窗口
    static func firstMinimizedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        return list.first { isMinimized($0) }
    }

    static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}

/// 「最小化记忆」：只装最近几次最小化的栈（后进先出）。
///
/// 做成泛型是为了能被自检直接验：真窗口造不出来，拿 Int 当值就能把
/// 顺序 / 过期 / 失效 / 上限这几条规则全钉住。
struct MinimizeMemory<Value> {

    private struct Entry {
        var value: Value
        var date: Date
    }

    private var entries: [Entry] = []
    /// 只留最近几次：用户开一堆最小化窗口时不能让它无限长
    let limit: Int

    init(limit: Int = 8) {
        self.limit = limit
    }

    var count: Int { entries.count }

    mutating func push(_ value: Value, at date: Date = Date()) {
        entries.append(Entry(value: value, date: date))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// 从最近的一次开始往外弹；跳过过期的，也跳过 `isStillValid` 说不用的。
    ///
    /// 拿出来的记录一定会从栈里删掉——哪怕它已经失效，留着也没意义了。
    mutating func pop(now: Date = Date(),
                      ttl: TimeInterval,
                      isStillValid: (Value) -> Bool) -> Value? {
        while let last = entries.last {
            entries.removeLast()
            guard now.timeIntervalSince(last.date) < ttl else { continue }
            guard isStillValid(last.value) else { continue }
            return last.value
        }
        return nil
    }

    /// 还有没有未过期的记录（只给决策用，不消耗，也不碰窗口）
    func hasCandidate(now: Date = Date(), ttl: TimeInterval) -> Bool {
        entries.contains { now.timeIntervalSince($0.date) < ttl }
    }
}

@MainActor
final class ActionRunner {

    static let shared = ActionRunner()

    /// 被我们最小化过的窗口，按时间堆着（后进先出）。
    ///
    /// 「最小化 → 还原」是这功能最常用的连招，但窗口一进 Dock，前台往往就换成了
    /// 别的应用（或桌面）。下一次手势解析出来的 context 已经指不到原来那个 app，
    /// 还原就成了空操作。所以最小化时把窗口记下来，还原时能跨应用找回去。
    ///
    /// 🔴 必须是**栈**不是单个记录：用户会连着最小化好几个应用，再一个个还原回来。
    /// 只记最后一次的时候，还原掉一个就空了，剩下的永远回不来
    /// （用户报的：「最小化了 3 个应用，最后还原的只有一个」）。
    private var minimizeStack = MinimizeMemory<(pid: pid_t, window: AXUIElement)>()

    /// 记忆有效期。超过这个时间就当用户已经不需要它了，避免莫名其妙把旧窗口捞出来。
    ///
    /// 原来只有 120 秒——太短了：最小化浏览器、回几条消息、再还原，记忆就过期了，
    /// 于是退回"当前应用的最小化窗口"，焦点又已经跳到 Finder，捞出来的就是文件夹。
    /// 5 分钟还能覆盖"最小化 → 干点别的 → 回来还原"这种正常节奏。
    private let minimizeMemory: TimeInterval = 300

    /// 执行动作，返回**是否真的做了**。
    ///
    /// 返回值只服务于屏幕反馈：「动作执行失败」必须提示，而且不受用户开关限制
    /// （用户关掉的只是"成功/未识别"这类噪音，失败是必须知道的）。
    /// 所以宁可保守——拿不准的一律算成功，只有明确没做成的才返回 false。
    @discardableResult
    func perform(_ action: GestureAction, context: TargetContext) -> Bool {
        switch action.kind {
        case .keystroke:
            guard let combo = action.keyCombo else { return false }
            postKeystroke(combo, context: context)
            return true
        case .openApp:
            guard let path = action.appPath else { return false }
            return openApp(path: path)
        case .openURL:
            guard let string = action.urlString else { return false }
            return openURL(string)
        case .media:
            guard let key = action.mediaKey else { return false }
            postMediaKey(key)
            return true
        case .window:
            guard let op = action.windowOp else { return false }
            return performWindow(op, context: context)
        case .browser:
            guard let op = action.browserOp else { return false }
            return performBrowser(op, context: context)
        }
    }

    // MARK: - 浏览器操作

    /// 浏览器操作全部用各浏览器通用的 ⌘ 组合键。
    ///
    /// 「复制当前页链接」是两步（⌘L 选中地址栏 → ⌘C），两步之间必须留间隔，
    /// 地址栏还没选中就把 ⌘C 发过去，复制到的是页面正文。
    @discardableResult
    private func performBrowser(_ op: BrowserOp, context: TargetContext) -> Bool {
        let combos = op.keyCombos
        guard let first = combos.first else { return false }
        postKeystroke(first, context: context)
        if combos.count > 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                // 第二步不用再激活：第一步已经等目标应用进了前台
                for combo in combos.dropFirst() {
                    self?.postKeystroke(combo)
                }
            }
        }
        return true
    }

    // MARK: - 键盘

    /// 打给"目标应用"而不是"现在的前台"。
    ///
    /// 需要一个激活步骤时，按键要等激活真的生效再发：`activate()` 是异步的，
    /// 立刻 post 出去的 ⌘T 还是会落进旧的前台应用里——这正是用户报的那个现象。
    func postKeystroke(_ combo: KeyCombo, context: TargetContext) {
        guard context.activatesTarget, let pid = context.pid else {
            postKeystroke(combo)
            return
        }
        activate(pid: pid) { [weak self] in self?.postKeystroke(combo) }
    }

    /// 把应用带到前台，等它真的 active 了再执行 body。
    private func activate(pid: pid_t, then body: @escaping () -> Void) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            body()
            return
        }
        if app.isActive {
            body()
            return
        }
        // 被 ⌘H 藏起来的应用光 activate 是叫不回来的（激活了还是隐藏状态）
        if app.isHidden { app.unhide() }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        // 轮询到真的到前台为止，最多等 0.4 秒（用户中途手动切走时别死等）
        var waited: TimeInterval = 0
        func poll() {
            if app.isActive || waited >= 0.4 {
                body()
                return
            }
            waited += 0.02
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
    }

    func postKeystroke(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: false) else {
            return
        }
        let flags = CGEventFlags(rawValue: combo.flags)
        down.flags = flags
        up.flags = flags
        // 🔴 和鼠标重放同一个标记：我们自己也监听 keyDown 匹配快捷键，
        // 不打标记的话「快捷键 A 的动作是发送快捷键 A」会自己触发自己，无限套娃。
        down.setIntegerValueField(.eventSourceUserData, value: GestureEngine.replayMark)
        up.setIntegerValueField(.eventSourceUserData, value: GestureEngine.replayMark)
        down.post(tap: .cghidEventTap)
        // 起手留一点点间隔：连发时系统和应用都更容易识别成一次完整按键
        usleep(12000)
        up.post(tap: .cghidEventTap)
    }

    // MARK: - 媒体键

    /// NSSystemDefined 合成媒体键。data1 高 16 位是 NX_KEYTYPE，低 16 位 0xA00 按下 / 0xB00 抬起。
    func postMediaKey(_ key: MediaKey) {
        postSystemDefined(key: key.nxKeyType, down: true)
        postSystemDefined(key: key.nxKeyType, down: false)
    }

    private func postSystemDefined(key: Int32, down: Bool) {
        let flags: Int32 = down ? 0xA00 : 0xB00
        let data1 = (Int(key) << 16) | Int(flags)
        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: 8,
                                             data1: data1,
                                             data2: down ? -1 : 1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }

    // MARK: - 应用 / URL

    @discardableResult
    func openApp(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        // 应用被删了 / 路径失效：这是最典型的一种「执行失败」
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    @discardableResult
    func openURL(_ string: String) -> Bool {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("://"), !trimmed.hasPrefix("mailto:") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }


    // MARK: - 窗口

    @discardableResult
    private func performWindow(_ op: WindowOp, context: TargetContext) -> Bool {
        // 「还原」先单独走一条路：窗口在 Dock 里的时候，用户要的是它回到桌面，
        // 而不是"取消缩放"。这一支不能落进下面的 applyWindow。
        if op == .restore, restoreWindow(context: context) {
            return true
        }

        if let window = context.window ?? context.pid.flatMap(TargetResolver.focusedWindow),
           applyWindow(op, to: window, pid: context.pid) {
            return true
        }
        // AX 不通 → 退到系统快捷键
        switch op {
        case .close:
            postKeystroke(KeyCombo(keyCode: 13, flags: CGEventFlags.maskCommand.rawValue, display: "⌘W"),
                          context: context)
            return true
        case .minimize:
            postKeystroke(KeyCombo(keyCode: 46, flags: CGEventFlags.maskCommand.rawValue, display: "⌘M"),
                          context: context)
            return true
        case .maximize, .restore:
            // macOS 没有「最大化」的系统快捷键，也没有可安全模拟的等价操作。
            // 双击标题栏最接近，但合成点击会落到窗口内容上，风险大于收益 → 什么都不做。
            // 拿不到窗口又没法兜底 —— 这就是真的一次「执行失败」，要告诉用户。
            return false
        case .fullScreen:
            postKeystroke(KeyCombo(keyCode: 3,
                                   flags: (CGEventFlags.maskControl.rawValue | CGEventFlags.maskCommand.rawValue),
                                   display: "⌃⌘F"))
            return true
        case .leftHalf, .rightHalf, .fillScreen,
             .leftThreeFifths,
             .leftTwoThirds, .rightTwoThirds, .leftThreeFourths, .rightThreeFourths,
             .topLeftQuarter, .centerTwoThirds, .centerThreeFourths:
            // 系统没有等价的快捷键：自带的"移到左侧/右侧"要靠按住标题栏悬停，
            // 合成不了。拿不到窗口就是真失败，别假装成功。
            return false
        }
    }

    // MARK: - 平铺 / 居中

    /// 平铺后的目标矩形（AX 坐标：原点在主屏左上角、y 向下）。
    ///
    /// 抽成纯函数是为了能自检：几何算错的表现是「窗口跑到屏幕外」或「差半像素发虚」，
    /// 真机上肉眼很难当场判定，只能把每个分支的边角用断言钉住。
    ///
    /// - Parameters:
    ///   - visible: 屏幕可用区（NSScreen.visibleFrame，NS 坐标、y 向上，已扣掉菜单栏和 Dock）
    ///   - flipBase: 主屏 `frame.maxY`，AX 与 NS 两套 y 轴互相翻转的基准
    static func tileFrame(_ op: WindowOp, in visible: CGRect, flipBase: CGFloat) -> CGRect? {
        guard visible.width > 1, visible.height > 1 else { return nil }

        // 尺寸与偏移都相对「可用区左上角」
        var size: CGSize
        var offset: CGPoint

        switch op {
        case .leftHalf:
            size = CGSize(width: (visible.width / 2).rounded(.down), height: visible.height)
            offset = .zero

        case .rightHalf:
            // 右半取"剩下的那一半"：宽度是奇数时也不会在中间留 1pt 缝或压 1pt
            let half = (visible.width / 2).rounded(.down)
            size = CGSize(width: visible.width - half, height: visible.height)
            offset = CGPoint(x: half, y: 0)

        case .fillScreen:
            // 满屏 = 可用区整块，菜单栏和 Dock 都留在外面。
            // 跟「切换全屏」是两回事：那个会把窗口塞进独立的全屏空间（绿点那种），
            // 而这里只是把窗口摆成可用区那么大，仍在当前桌面上、Dock 照常能唤出。
            size = CGSize(width: visible.width, height: visible.height)
            offset = .zero

        case .leftTwoThirds, .rightTwoThirds, .leftThreeFourths, .rightThreeFourths,
             .leftThreeFifths:
            // 左右同宽：宽度只按比例算一次，贴右时用「可用区右边界减宽度」定位。
            // 反过来写（右半取"剩下的那部分"）会让 1710×2/3 这类含小数的宽度
            // 在左右两侧算出不同宽度，同一个 2/3 一左一右看着不一样宽。
            let ratio: CGFloat
            switch op {
            case .leftTwoThirds, .rightTwoThirds:       ratio = 2.0 / 3.0
            case .leftThreeFourths, .rightThreeFourths: ratio = 3.0 / 4.0
            default:                                    ratio = 3.0 / 5.0
            }
            let width = (visible.width * ratio).rounded(.down)
            size = CGSize(width: width, height: visible.height)
            let alignedRight = (op == .rightTwoThirds || op == .rightThreeFourths)
            offset = CGPoint(x: alignedRight ? visible.width - width : 0, y: 0)

        case .topLeftQuarter:
            // 1/4 屏 = 宽高各一半，贴左上角
            size = CGSize(width: (visible.width / 2).rounded(.down),
                          height: (visible.height / 2).rounded(.down))
            offset = .zero

        case .centerTwoThirds, .centerThreeFourths:
            // 只缩宽度、上下满高。这两个动作要的是"窄一点的窗口"，
            // 不是"小一号的窗口"——后者四边都缩，中文文档会横向被挤得很窄。
            let ratio: CGFloat = op == .centerTwoThirds ? 2.0 / 3.0 : 3.0 / 4.0
            let width = (visible.width * ratio).rounded(.down)
            size = CGSize(width: width, height: visible.height)
            offset = CGPoint(x: ((visible.width - width) / 2).rounded(.down), y: 0)

        default:
            return nil
        }

        return CGRect(x: visible.minX + offset.x,
                      y: flipBase - visible.maxY + offset.y,
                      width: size.width,
                      height: size.height)
    }

    /// 把窗口摆到平铺位置。
    ///
    /// 全屏状态下改不了 frame（AX 会忽略），得先退全屏、等动画走完再摆，
    /// 所以这一支是异步的——返回 true 表示"动作已受理"。
    private func tileWindow(_ op: WindowOp, to window: AXUIElement) -> Bool {
        guard let current = windowFrame(window),
              let host = visibleFrame(axCenter: CGPoint(x: current.midX, y: current.midY)),
              let target = Self.tileFrame(op, in: host.frame, flipBase: host.flipBase) else {
            return false
        }

        let isFullScreen = (attribute(window, "AXFullScreen" as CFString) as? NSNumber)?.boolValue ?? false
        if isFullScreen {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanFalse)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.placeWindow(window, to: target)
            }
            return true
        }
        return placeWindow(window, to: target)
    }

    /// 分拍摆窗口：先位置 → 等它**真的画到**目标位置 → 再尺寸 → 补位置。
    ///
    /// 🔴 这就是「窗口操作要执行两次才准」的根因与修法。
    ///
    /// Chromium / Electron（Edge、WorkBuddy）把 AX 的位置变更做成了约 200ms 的
    /// **平滑过渡**。而且 AX 的 position 属性在写入后**立刻**就报目标值（乐观更新），
    /// 读属性根本看不出过渡还在走 —— 在过渡途中写尺寸，窗口会被定格甚至弹回起点。
    /// 实测（`BoxMouse --windowseq`，目标 x=570 w=1140，起点左半屏 x=0 w=855）：
    ///
    /// | 调用序列 | 结果 |
    /// |---|---|
    /// | position → size（旧实现） | x=0 w=1140，位置整个丢了 |
    /// | position → 120ms → size | x=499，停在过渡中间 |
    /// | position → 280ms → size | x=570 w=1140 ✅ |
    ///
    /// 真实渲染位置的过渡轨迹（CGWindowList 采样，40ms 一拍）：
    /// x = 236 → 468 → 541 → 568 → 570，约 200ms 到位；而 AX 读回一直报 570。
    ///
    /// 所以判「到位」只能读**合成器的真实位置**（CGWindowList）。原生 AppKit 应用
    /// 是瞬时就位的，轮询第一拍就能过，不会有额外延迟；只有真有过渡的应用才等。
    ///
    /// 用户看到的现象正好对得上：左 1/2 → 右 2/3 时，第一次只有位置动了、尺寸被
    /// 过渡吞掉，第二次因为位置已经是同值（没有过渡）尺寸才生效。
    @discardableResult
    private func placeWindow(_ window: AXUIElement, to target: CGRect) -> Bool {
        guard let before = windowFrame(window) else { return false }

        // 位置本来就在目标上：不会有过渡，直接写尺寸（重复按同一个操作走这条路）
        if Self.isSame(before.origin, target.origin) {
            return Self.setSize(window, target.size)
        }
        guard Self.setPosition(window, target.origin) else { return false }

        // 记下这个窗口在合成器里的编号，后面只盯它自己的真实位置。
        // AX 没有窗口编号属性，只能按「位置 + 尺寸与 AX 读数最接近」认。
        let number = Self.windowNumber(of: window, near: before)
        waitForRenderedPosition(window, number: number, target: target, attempt: 0)
        return true
    }

    /// 轮询合成器位置，等窗口真的画到位再写尺寸。20ms 一拍，最多 20 拍（400ms）。
    ///
    /// 等太久也不能不响应：超过上限照样写尺寸，宁可位置差一点，
    /// 也好过用户按了手势什么都没发生。
    private func waitForRenderedPosition(_ window: AXUIElement,
                                         number: CGWindowID?,
                                         target: CGRect,
                                         attempt: Int) {
        let arrived: Bool
        if let number, let rendered = Self.renderedOrigin(of: number) {
            // 3pt 容差：过渡尾段会有一两像素的余量，卡太死会白等好几拍
            arrived = Self.isSame(rendered, target.origin, tolerance: 3)
        } else {
            // 认不出合成器里的窗口（多窗口应用、窗口被别的窗口完全盖住等）：
            // 保守地按 Chromium 的过渡时长等满 260ms，再退回原来的行为
            arrived = attempt >= 13
        }
        guard !arrived, attempt < 20 else {
            finishTiling(window, target: target)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.waitForRenderedPosition(window, number: number,
                                          target: target, attempt: attempt + 1)
        }
    }

    /// 位置到位了，写尺寸，最后补一次位置。
    private func finishTiling(_ window: AXUIElement, target: CGRect) {
        guard Self.setSize(window, target.size) else { return }
        // 改尺寸会按 NS 的左下角锚点带偏位置（改高度时尤其明显：「左上 1/4」
        // 把高度砍半，底边不动、顶边就跑了）。100ms 后补一次 —— 那时位置过渡
        // 早已结束，补位置不会反过来把尺寸打回。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let now = self.windowFrame(window),
                  !Self.isSame(now.origin, target.origin) else { return }
            _ = Self.setPosition(window, target.origin)
        }
    }

    /// 两个坐标是否在容差内相等。
    /// 各应用的取整习惯不同（实测 1016 会报成 1015、1140 会报成 1137），
    /// 不留容差会让轮询永远等不到「到位」。
    private static func isSame(_ a: CGPoint, _ b: CGPoint, tolerance: CGFloat = 1) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }

    /// 这个 AX 窗口在合成器里对应哪个窗口号。
    /// 按「位置 + 尺寸与 AX 读数最接近」认 —— 多窗口应用里也只能这么认。
    private static func windowNumber(of window: AXUIElement, near frame: CGRect) -> CGWindowID? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var best: (number: CGWindowID, distance: CGFloat)?
        for info in list {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner == pid,
                  let number = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  w > 100, h > 100 else { continue }
            let distance = abs(x - frame.minX) + abs(y - frame.minY)
                + abs(w - frame.width) + abs(h - frame.height)
            if best == nil || distance < best!.distance {
                best = (number, distance)
            }
        }
        return best?.number
    }

    /// 这个窗口号现在**真的画在**哪（合成器坐标，与 AX 一样是从主屏顶部往下）。
    /// 只查这一个窗口，比拉全量列表便宜得多。
    private static func renderedOrigin(of number: CGWindowID) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], number)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let infoNumber = info[kCGWindowNumber as String] as? CGWindowID,
                  infoNumber == number,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"] else { continue }
            return CGPoint(x: x, y: y)
        }
        return nil
    }

    @discardableResult
    private static func setPosition(_ window: AXUIElement, _ origin: CGPoint) -> Bool {
        var value = origin
        guard let axValue = AXValueCreate(.cgPoint, &value) else { return false }
        return AXUIElementSetAttributeValue(window,
                                            kAXPositionAttribute as CFString,
                                            axValue) == .success
    }

    @discardableResult
    private static func setSize(_ window: AXUIElement, _ size: CGSize) -> Bool {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else { return false }
        return AXUIElementSetAttributeValue(window,
                                            kAXSizeAttribute as CFString,
                                            axValue) == .success
    }

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
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

    /// 给定 AX 坐标里的一个点，返回它所在屏幕的可用区矩形，以及 y 轴翻转基准。
    private func visibleFrame(axCenter: CGPoint) -> (frame: CGRect, flipBase: CGFloat)? {
        let screens = NSScreen.screens
        guard let main = screens.first else { return nil }
        let flipBase = main.frame.maxY
        let probe = CGPoint(x: axCenter.x, y: flipBase - axCenter.y)
        let screen = screens.first { $0.frame.contains(probe) } ?? NSScreen.main ?? main
        return (screen.visibleFrame, flipBase)
    }

    /// 还原时要动哪个窗口。
    ///
    /// 抽成纯函数是因为"顺序"就是这个功能的全部逻辑，而顺序写错的表现很具体：
    /// 最小化浏览器 → 焦点自动跳到 Finder → 再还原，如果按"当前应用"找，
    /// 捞出来的就是 Finder 里那个最小化的文件夹（用户看到的：
    /// 「无论我最小化哪个应用，还原出来的都是文件夹」）。这种错只能靠自检钉住。
    enum RestoreTarget: Equatable {
        /// 起手时锁定的那个窗口本身就在 Dock 里
        case startWindow
        /// 起手窗口在台面上、而且是最大化的 → 用户要的是"取消缩放"
        case cancelZoom
        /// 上一次被我们最小化的窗口（跨应用）
        case remembered
        /// 当前应用自己的最小化窗口
        case currentApp
        case nothing
    }

    static func restorePlan(startWindowExists: Bool,
                            startMinimized: Bool,
                            startFillingScreen: Bool,
                            hasRemembered: Bool,
                            hasCurrentAppMinimized: Bool) -> RestoreTarget {
        if startWindowExists && startMinimized { return .startWindow }
        if startWindowExists && startFillingScreen { return .cancelZoom }
        // 🔴 记忆必须排在"当前应用"前面：见上面那段注释
        if hasRemembered { return .remembered }
        if hasCurrentAppMinimized { return .currentApp }
        return .nothing
    }

    /// 「还原窗口」：把藏起来的窗口弄回桌面。
    private func restoreWindow(context: TargetContext) -> Bool {
        let startWindow = context.window
        let startMinimized = startWindow.map { TargetResolver.isMinimized($0) } ?? false
        let startFilling = startWindow.map { isFillingScreen($0) } ?? false
        let hasRemembered = minimizeStack.hasCandidate(ttl: minimizeMemory)
        let currentAppWindow = context.pid.flatMap { TargetResolver.firstMinimizedWindow(pid: $0) }

        let plan = Self.restorePlan(startWindowExists: startWindow != nil,
                                    startMinimized: startMinimized,
                                    startFillingScreen: startFilling,
                                    hasRemembered: hasRemembered,
                                    hasCurrentAppMinimized: currentAppWindow != nil)

        switch plan {
        case .startWindow:
            guard let startWindow else { return false }
            // 起手锁定的窗口没有 pid（按窗口模式），从窗口自己反查，别把它漏到后台去
            return unminimize(startWindow, pid: context.pid ?? TargetResolver.processID(of: startWindow))

        case .cancelZoom:
            // 交给 applyWindow 去点缩放按钮
            return false

        case .remembered:
            // 一条一条往外弹：弹出来的那些可能已经被用户手动恢复或关掉了，
            // 跳过它们继续找下一个真正还躺在 Dock 里的窗口。
            while let record = minimizeStack.pop(ttl: minimizeMemory,
                                                 isStillValid: { TargetResolver.isMinimized($0.window) }) {
                if unminimize(record.window, pid: record.pid) { return true }
            }
            // 记忆全失效 → 退回当前应用自己的最小化窗口
            if let pid = context.pid, let window = currentAppWindow {
                return unminimize(window, pid: pid)
            }
            return false

        case .currentApp:
            guard let pid = context.pid, let window = currentAppWindow else { return false }
            return unminimize(window, pid: pid)

        case .nothing:
            return false
        }
    }

    /// 取消最小化，并确保窗口真的"出现在桌面上"。
    ///
    /// 只设 `AXMinimized = false` 窗口会回到它原来的位置 —— 但那个位置此时
    /// 很可能被别的应用整片盖住，或者应用本身就在后台。用户报的"执行还原，
    /// 它没有出现在桌面"就是这个：窗口回来了，但你看不见。
    /// 所以四件事一起做：取消最小化 → 应用前置为最前 → 窗口提到最上层 → 设为该应用主窗口。
    private func unminimize(_ window: AXUIElement, pid: pid_t?) -> Bool {
        guard AXUIElementSetAttributeValue(window,
                                           kAXMinimizedAttribute as CFString,
                                           kCFBooleanFalse) == .success else { return false }

        guard let pid else { return true }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        // AX 的前置偶尔会被系统忽略（另一个应用正在抢焦点），再补一次 Cocoa 侧的激活
        NSRunningApplication(processIdentifier: pid)?.activate()
        return true
    }

    private func applyWindow(_ op: WindowOp, to window: AXUIElement, pid: pid_t?) -> Bool {
        switch op {
        case .close:
            guard let button = attribute(window, kAXCloseButtonAttribute as CFString) else { return false }
            return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success

        case .minimize:
            guard AXUIElementSetAttributeValue(window,
                                               kAXMinimizedAttribute as CFString,
                                               kCFBooleanTrue) == .success else { return false }
            // 记下这一笔，供「还原」在焦点已经跑掉时找回来
            if let pid {
                minimizeStack.push((pid: pid, window: window))
            } else if let ownerPID = TargetResolver.processID(of: window) {
                minimizeStack.push((pid: ownerPID, window: window))
            }
            return true

        case .maximize:
            // 已经是最大了就不能再点缩放按钮——那会变成还原，正好反了
            guard !isFillingScreen(window) else { return true }
            guard !TargetResolver.isMinimized(window) else { return unminimize(window, pid: pid) }
            return pressZoomButton(window)

        case .restore:
            // 最小化的情况已经在 restoreWindow 里处理掉了，走到这里说明窗口在台面上
            guard isFillingScreen(window) else { return true }
            return pressZoomButton(window)

        case .fullScreen:
            guard let current = attribute(window, "AXFullScreen" as CFString) as? NSNumber else { return false }
            let target = current.boolValue ? kCFBooleanFalse : kCFBooleanTrue
            return AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, target!) == .success

        case .leftHalf, .rightHalf, .fillScreen,
             .leftThreeFifths,
             .leftTwoThirds, .rightTwoThirds, .leftThreeFourths, .rightThreeFourths,
             .topLeftQuarter, .centerTwoThirds, .centerThreeFourths:
            return tileWindow(op, to: window)
        }
    }

    private func pressZoomButton(_ window: AXUIElement) -> Bool {
        guard let button = attribute(window, kAXZoomButtonAttribute as CFString) else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// 窗口是否已经铺满屏幕的可用区域。
    ///
    /// AX 没有「是否已缩放」这类属性，缩放按钮本身也不带状态，只能按几何比。
    /// 这也是 Rectangle / Magnet 一类窗口管理器的通行做法：把窗口尺寸和
    /// NSScreen.visibleFrame（已扣掉菜单栏和 Dock）比，容差留给各应用的细微差异。
    private func isFillingScreen(_ window: AXUIElement) -> Bool {
        // AXValue 是 CF 类型，`as?` 恒真，得靠 typeID 判断真实类型
        guard let sizeRef = attribute(window, kAXSizeAttribute as CFString),
              let posRef = attribute(window, kAXPositionAttribute as CFString),
              CFGetTypeID(sizeRef) == AXValueGetTypeID(),
              CFGetTypeID(posRef) == AXValueGetTypeID() else {
            return false
        }
        var size = CGSize.zero
        var origin = CGPoint.zero
        guard AXValueGetValue(sizeRef as! AXValue, .cgSize, &size),
              AXValueGetValue(posRef as! AXValue, .cgPoint, &origin),
              let visible = visibleScreenSize(axPoint: origin) else {
            return false
        }
        let tolerance: CGFloat = 12
        return abs(size.width - visible.width) <= tolerance
            && abs(size.height - visible.height) <= tolerance
    }

    /// 给定窗口位置（AX 坐标，原点在主屏左上、y 向下），返回它所在屏幕的可用区域尺寸。
    private func visibleScreenSize(axPoint: CGPoint) -> CGSize? {
        guard let main = NSScreen.screens.first else { return nil }
        // AX 与 NSScreen 的 y 轴方向相反，得翻过来才能判断窗口落在哪块屏
        let flipBase = main.frame.maxY
        let probe = CGPoint(x: axPoint.x, y: flipBase - axPoint.y)
        let screen = NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main ?? main
        return screen.visibleFrame.size
    }

    private func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}
