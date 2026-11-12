import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// ============================================================
// 界面状态
//
// 视图只读这里的派生数据（visibleGestures），不做二次过滤——
// 侧栏计数、表格行、批量操作必须永远看同一份集合，否则
// 「显示 8 条、全选却选了 12 条」这种错很难自查。
// ============================================================

enum MainTab: String, CaseIterable, Identifiable {
    case gestures
    case mouse
    case general
    case permissions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gestures:    return "手势"
        case .mouse:       return "鼠标"
        case .general:     return "通用"
        case .permissions: return "权限"
        case .about:       return "关于"
        }
    }

    var symbolName: String {
        switch self {
        case .gestures:    return "hand.draw"
        case .mouse:       return "computermouse"
        case .general:     return "slider.horizontal.3"
        case .permissions: return "lock.shield"
        case .about:       return "info.circle"
        }
    }
}

enum EnabledFilter: String, CaseIterable, Identifiable {
    case all, enabled, disabled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:      return "全部"
        case .enabled:  return "已启用"
        case .disabled: return "已禁用"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, trigger, created, updated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name:    return "名称"
        case .trigger: return "触发键"
        case .created: return "创建时间"
        case .updated: return "修改时间"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {

    /// 一次成功触发（菜单栏浮窗的"最近触发"）
    struct FiredEvent: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let trigger: String
        let path: [PathPoint]
        let at: Date
    }

    let store: GestureStore
    let engine: GestureEngine
    /// 触摸板手势引擎。本机没有可用触控板接口时它照样存在，只是不跑。
    let trackpad: TrackpadEngine

    // 界面状态
    @Published var selectedTab: MainTab = .gestures
    @Published var selectedScopeID: UUID
    @Published var searchText: String = ""
    @Published var enabledFilter: EnabledFilter = .all
    @Published var kindFilter: GestureKindFilter = .all
    @Published var sortKey: SortKey = .name
    @Published var ascending: Bool = true
    @Published var selection: Set<UUID> = []

    /// 编辑中的手势（nil = 没开编辑器）
    @Published var editingGesture: Gesture?
    @Published var isCreatingGesture = false

    /// 正在编辑成员的应用组（nil = 没开）。侧栏右键、行尾按钮、主区标题旁都指向它
    @Published var editingGroup: ScopeEntry?

    /// 权限状态（定时刷新）
    @Published private(set) var hasAccessibility = false
    /// 触摸板手势要的「输入监控」，跟辅助功能是两项独立的授权
    @Published private(set) var hasInputMonitoring = false
    @Published private(set) var engineRunning = false
    /// 键盘监听是否挂上了。false 表示缺「输入监控」，鼠标手势正常、快捷键不生效
    @Published private(set) var keyboardAvailable = true
    /// 触摸板引擎是否在跑（没有启用的触摸板手势时它是停的，权限页要据此说明原因）
    @Published private(set) var trackpadRunning = false

    @Published var toast: String?

    /// 最近触发记录，新的在前（浮窗最多显示 3 条）
    @Published private(set) var recentFires: [FiredEvent] = []

    /// 由 AppDelegate 注入：菜单栏浮窗要能把主窗口唤回来
    /// （隐藏了 Dock 图标之后，这是唯一的入口）
    var openWindow: ((MainTab?) -> Void)?

    private var cancellables = Set<AnyCancellable>()
    private var permissionTimer: Timer?
    private var toastWorkItem: DispatchWorkItem?

    // MARK: - 触摸板画轨迹的屏幕浮层
    //
    // 触控板是"盲画"：没有反馈时用户不知道画成了什么，画歪了还以为是应用没反应。
    // 浮层只在「这一轮可能命中画轨迹手势」时才出现——否则单指移动指针时
    // 屏幕上会一直拖着一条线，比不画还吵。
    private let trackpadTrail = TrailOverlay()
    /// 起手时的指针位置（屏幕坐标，y 向下）。画的过程中指针会跟着动，
    /// 用它当锚点才不会"追着指针跑"
    private var trailAnchor: CGPoint?
    /// 起手时的触控板坐标（y 已翻成屏幕方向）
    private var trailOrigin: CGPoint?
    /// 这一轮要不要画
    private var trailArmed = false
    /// 浮层是否已经创建（延迟到真开始画，避免单击闪一下）
    private var trailShown = false

    init(store: GestureStore, engine: GestureEngine, trackpad: TrackpadEngine) {
        self.store = store
        self.engine = engine
        self.trackpad = trackpad
        self.selectedScopeID = store.globalScope.id
    }

    func bootstrap() {
        hasAccessibility = Permissions.hasAccessibility
        hasInputMonitoring = Permissions.hasInputMonitoring

        // 诊断用一次性开关：`defaults write com.pcxx.boxmousemac openTab mouse`
        // 后启动直接落到指定标签页，供自动化截图用。读完立刻删，
        // 正常使用不会有人去写它（和 demoRecentFires 同一性质）。
        if let wanted = UserDefaults.standard.string(forKey: "openTab"),
           let tab = MainTab(rawValue: wanted) {
            UserDefaults.standard.removeObject(forKey: "openTab")
            selectedTab = tab
        }

        engine.sync()
        engineRunning = engine.isRunning
        keyboardAvailable = engine.keyboardTapAvailable

        // 手势触发 → 记录（只做展示，不参与任何逻辑）
        engine.onResult = { [weak self] outcome in
            self?.handleOutcome(outcome)
        }

        // 触摸板手势：识别出来之后按作用域找候选，命中就走同一条动作通道。
        // 识别结果已经在主线程（引擎自己 dispatch 回来的）。
        trackpad.onGesture = { [weak self] report in
            self?.handleTrackpad(report)
        }
        trackpad.onTrailStart = { [weak self] modifiers in
            self?.beginTrackpadTrail(modifiers: modifiers)
        }
        trackpad.onTrailPoint = { [weak self] point in
            self?.appendTrackpadTrail(point)
        }
        trackpad.onTrailEnd = { [weak self] in
            self?.endTrackpadTrail()
        }
        // 不再无条件启动：没有启用的触摸板手势就不碰 MultitouchSupport
        syncTrackpadEngine()

        // store 是独立的 ObservableObject，但界面全都只认 AppModel。
        // 不转发的话，改设置/删手势之后视图不会重绘——
        // 绑定型控件（开关、颜色）甚至会当场弹回原值。
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // 设置变化 → 引擎跟着起停（例如用户关掉总开关）
        store.$settings
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                self.engine.sync()
                self.engineRunning = self.engine.isRunning
                self.syncTrackpadEngine()
            }
            .store(in: &cancellables)

        // 设置是 debounce 写盘的；切走应用（或点别的窗口）时把窗口里那笔落盘。
        // 只靠 applicationWillTerminate 不够：SIGTERM / 崩溃都不走它。
        NotificationCenter.default
            .publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in self?.store.flushSettings() }
            .store(in: &cancellables)

        // 手势库变化（新增/删除/启用停用触摸板手势）→ 触摸板引擎跟着起停。
        // didChangeLibrary 是在改动**之后**发的，读到的已经是新状态。
        store.didChangeLibrary
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.syncTrackpadEngine() }
            .store(in: &cancellables)

        // 手动授予辅助功能之前，引擎根本不会跑，也没法验证「最近触发」的版式。
        // 一次性开关：读完立刻清掉，正常使用不会有人打开它。
        if UserDefaults.standard.bool(forKey: "demoRecentFires") {
            UserDefaults.standard.removeObject(forKey: "demoRecentFires")
            for (offset, gesture) in store.gestures.prefix(3).enumerated() {
                recentFires.append(FiredEvent(name: gesture.name,
                                              trigger: gesture.trigger.displayName,
                                              path: gesture.path,
                                              at: Date().addingTimeInterval(-Double(offset) * 47)))
            }
        }

        // 首次启动若没授权，直接弹系统引导：不弹的话用户根本不知道要授权。
        // suppressAccessibilityPrompt 只给自动化验证用（截图时不想被弹窗挡住），
        // 正常使用不会有人去关它。
        if !hasAccessibility && !UserDefaults.standard.bool(forKey: "suppressAccessibilityPrompt") {
            Permissions.requestAccessibility()
        }

        // 触摸板手势还要「输入监控」。缺它的时候引擎会"启动成功"却不回帧，
        // 从界面上看不出是权限问题，所以启动时就主动弹一次（系统只弹一次）。
        if TrackpadEngine.isAvailable,
           !hasInputMonitoring,
           !UserDefaults.standard.bool(forKey: "suppressAccessibilityPrompt") {
            Permissions.requestInputMonitoring()
        }

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func shutdown() {
        permissionTimer?.invalidate()
        engine.stop()
        trackpad.stop()
        // 设置是 debounce 写盘的：退出前必须把窗口里那一笔补上，否则刚改的就丢了
        store.flushSettings()
    }

    func refreshPermissions() {
        // 🔴 每个 @Published 赋值都会触发一次界面更新。以前这里
        // 「输入监控」「引擎在跑」两项是无条件赋值的：状态没变也每 2 秒
        // 让整个主窗口重排一次。三项全部先判等再写。
        let monitoring = Permissions.hasInputMonitoring
        if monitoring != hasInputMonitoring { hasInputMonitoring = monitoring }

        let granted = Permissions.hasAccessibility
        if granted != hasAccessibility { hasAccessibility = granted }

        // 判据是 needsEventTap：鼠标控制（滚轮/侧键动作）也靠这只 tap，
        // 用户只开平滑滚轮、不开手势时同样要在授权后把 tap 挂上。
        if granted && !engine.isRunning && store.settings.needsEventTap {
            engine.sync()
        }

        let running = engine.isRunning
        if running != engineRunning { engineRunning = running }

        // 键盘监听挂不上时（缺「输入监控」），鼠标手势是好的、只有快捷键不灵。
        // 这个差别必须在界面上说清楚，否则用户只会觉得"快捷键功能坏了"。
        let keyboard = engine.keyboardTapAvailable
        if keyboard != keyboardAvailable { keyboardAvailable = keyboard }
    }

    /// 重启触摸板引擎。
    ///
    /// 触控板设备是在应用启动那一刻启动的。如果用户是**先开应用、后授权**，
    /// 那一刻系统还没给权限，设备就是以"没权限"的状态起来的，
    /// 之后再授权也不会自己好起来——必须把设备重新起一次。
    /// 触摸板引擎该不该跑：总开关开着，且真的有一条启用的触摸板手势。
    var trackpadNeeded: Bool {
        TrackpadEngine.shouldRun(engineEnabled: store.settings.engineEnabled,
                                 gestures: store.gestures)
    }

    var hasEnabledTrackpadGestures: Bool {
        store.gestures.contains { $0.kind == .trackpad && $0.enabled }
    }

    /// 按需启停触摸板引擎。任何影响「该不该跑」的变动之后都要调一次：
    /// 总开关、手势的新增/删除/启停。
    /// 上次已经提示过的失败原因（避免每次改设置都弹一遍）
    private var reportedTrackpadFailure: String?

    func syncTrackpadEngine() {
        trackpad.sync(shouldRun: trackpadNeeded)
        if trackpadRunning != trackpad.isRunning {
            trackpadRunning = trackpad.isRunning
        }

        // 引擎「起不来」以前是完全静默的：用户勾了手势，界面上什么都没有，
        // 表现就是「手势无效」。现在同一个原因提示一次（换原因才再提示），
        // 并且 reason 已经同时写进 trackpad-trace.log。
        if let reason = TrackpadEngine.failureReport(needed: trackpadNeeded,
                                                     running: trackpad.isRunning,
                                                     reason: TrackpadEngine.lastFailure),
           reason != reportedTrackpadFailure {
            reportedTrackpadFailure = reason
            showToast("触摸板引擎没起来：\(reason)")
        }
        if trackpad.isRunning { reportedTrackpadFailure = nil }
    }

    func restartTrackpadEngine() {
        guard trackpadNeeded else {
            // 没有启用的触摸板手势时重启毫无意义，还白加载一次私有框架
            showToast(store.settings.engineEnabled
                      ? "没有启用的触摸板手势，引擎保持停用"
                      : "总开关已关，先打开总开关")
            return
        }
        trackpad.stop()
        // 停掉之后立刻重启，MTDeviceStart 需要一点时间准备
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.syncTrackpadEngine()
        }
        showToast("触摸板引擎已重启")
    }

    // MARK: - 当前作用域

    var selectedScope: ScopeEntry {
        store.scope(id: selectedScopeID) ?? store.globalScope
    }

    // MARK: - 概览（菜单栏浮窗用）

    var totalGestureCount: Int { store.gestures.count }

    var enabledGestureCount: Int { store.gestures.filter(\.enabled).count }

    var appScopeCount: Int { store.scopes.filter { $0.kind != .global }.count }

    private func recordFired(_ gesture: Gesture) {
        let event = FiredEvent(name: gesture.name,
                               trigger: gesture.triggerDescription,
                               path: gesture.path,
                               at: Date())
        recentFires.insert(event, at: 0)
        if recentFires.count > 3 {
            recentFires.removeLast(recentFires.count - 3)
        }
    }

    // MARK: - 触摸板

    /// 触摸板识别结果 → 找候选 → 执行。
    ///
    /// 目标应用沿用同一套判定：设成「前台应用」就直接拿前台的；
    /// 设成「指针所在」才去问指针。触摸板没有鼠标位置的概念，
    /// 但指针通常还停在用户上一步操作的地方，语义仍成立。
    private func handleTrackpad(_ report: TrackpadReport) {
        guard store.settings.engineEnabled else { return }
        // CGEvent 的坐标与 AX 一致（原点在主屏左上，y 向下），不要用 NSEvent.mouseLocation，
        // 那是 Cocoa 坐标，y 是反的
        let point = CGEvent(source: nil)?.location ?? .zero
        let context = TargetResolver.resolve(mode: store.settings.targetMode,
                                             point: point,
                                             lockWindow: false)

        let candidates = store.trackpadCandidates(event: report.event,
                                                  modifiers: report.modifiers,
                                                  bundleID: context.bundleID)
        guard let gesture = candidates.first else {
            presentFeedback(.unmatched)
            return
        }
        let didRun = ActionRunner.shared.perform(gesture.action, context: context)
        handleOutcome(didRun ? .matched(gesture) : .failed(gesture))
    }

    // MARK: - 手势反馈

    /// 一轮手势结束：记录 + 按设置弹提示。
    ///
    /// 「执行失败」不受开关影响——用户关掉的只是成功/未识别这类噪音，
    /// 失败说明"手势做了但没成"，必须让他知道（这也是静默启动之后
    /// 唯一能告诉他的渠道）。
    private func handleOutcome(_ outcome: GestureEngine.FireOutcome) {
        switch outcome {
        case let .matched(gesture):
            recordFired(gesture)
            presentFeedback(.success(gesture.name))
        case let .failed(gesture):
            recordFired(gesture)
            presentFeedback(.failure(gesture.name))
        case .unmatched:
            presentFeedback(.unmatched)
        }
        // 一轮手势到此结束：交给静默自回收去排一次"静置后归还"。
        // 放在这个漏斗里而不是各个分支里，是因为三条路径（鼠标/触摸板/快捷键）
        // 最终都收敛到 handleOutcome，漏一条就少一次回收机会。
        MemoryReclaimer.shared.gestureDidFinish()
    }

    private func presentFeedback(_ kind: FeedbackHUD.Kind) {
        // 总开关关着的时候引擎本来就不该有输出，提示也别弹
        guard store.settings.engineEnabled else { return }
        guard FeedbackHUD.shouldShow(kind,
                                     showSuccess: store.settings.showSuccessFeedback,
                                     showUnmatched: store.settings.showUnrecognizedFeedback) else {
            return
        }
        FeedbackHUD.shared.show(kind)
    }

    // MARK: - 触摸板画轨迹浮层

    private func beginTrackpadTrail(modifiers: Set<ModifierKey>) {
        endTrackpadTrail()

        guard store.settings.showTrail, store.settings.engineEnabled else { return }
        // 只有这一轮「按着这组修饰键可能命中画轨迹手势」才画。
        // 否则单指移动指针的每一帧都会往屏幕上画线，整天都在闪。
        let armed = store.gestures.contains {
            $0.kind == .trackpad && $0.enabled
                && $0.trackpad?.pattern == .path
                && $0.modifiers == modifiers
        }
        guard armed else { return }

        trailArmed = true
        trailAnchor = CGEvent(source: nil)?.location
    }

    private func appendTrackpadTrail(_ point: CGPoint) {
        guard trailArmed, let anchor = trailAnchor else { return }

        // 起手点记为原点：屏幕轨迹 = 锚点 + (触控板位移 × 比例)
        guard let origin = trailOrigin else {
            trailOrigin = point
            return
        }

        // 比例：触控板一条边 ≈ 屏幕短边的 45%。1:1 会大得离谱
        // （触控板 11cm 的横线铺满 1400px 宽的屏幕），太小又看不清形状。
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        let shortSide = min(screen?.frame.width ?? 1440, screen?.frame.height ?? 900)
        let scale = shortSide * 0.45
        let mapped = Self.trailScreenPoint(point, origin: origin,
                                           anchor: anchor, scale: scale)

        if !trailShown {
            // 和鼠标手势一样：移动满 6pt 才创建浮层，单击/轻点不闪
            guard hypot(mapped.x - anchor.x, mapped.y - anchor.y) >= 6 else { return }
            trailShown = true
            trackpadTrail.show(at: anchor,
                               color: NSColor(hexString: store.settings.trailColorHex) ?? .systemRed,
                               width: store.settings.trailWidth)
            trackpadTrail.append(mapped)
            return
        }
        trackpadTrail.append(mapped)
    }

    /// 触控板坐标 → 屏幕坐标。
    ///
    /// 锚点是起手时的指针位置，起手点为原点做等比放大：
    /// `屏幕 = 锚点 + (触控板位移 × scale)`。
    /// 传入的触控板坐标 y 已经翻成屏幕方向（向下为正，引擎负责翻转），
    /// 所以这里不需要再动 y。
    static func trailScreenPoint(_ point: CGPoint,
                                 origin: CGPoint,
                                 anchor: CGPoint,
                                 scale: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x + (point.x - origin.x) * scale,
                y: anchor.y + (point.y - origin.y) * scale)
    }

    private func endTrackpadTrail() {
        trackpadTrail.hide()
        trailArmed = false
        trailShown = false
        trailAnchor = nil
        trailOrigin = nil
    }

    // MARK: - 派生列表

    var visibleGestures: [Gesture] {
        var result = store.gestures.filter { $0.scopeID == selectedScopeID }

        switch enabledFilter {
        case .all:      break
        case .enabled:  result = result.filter(\.enabled)
        case .disabled: result = result.filter { !$0.enabled }
        }

        if let kind = kindFilter.kind {
            // 按触发方式分组筛：鼠标手势 / 触摸板手势 / 快捷键各一类
            result = result.filter { $0.kind == kind }
        }

        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !keyword.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(keyword)
                || $0.action.summary.localizedCaseInsensitiveContains(keyword)
                || $0.triggerDescription.localizedCaseInsensitiveContains(keyword)
            }
        }

        result.sort { lhs, rhs in
            let ordered: Bool
            switch sortKey {
            case .name:    ordered = lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            case .trigger: ordered = lhs.trigger.rawValue < rhs.trigger.rawValue
            case .created: ordered = lhs.createdAt < rhs.createdAt
            case .updated: ordered = lhs.updatedAt < rhs.updatedAt
            }
            return ascending ? ordered : !ordered
        }
        return result
    }

    var selectionInView: Set<UUID> {
        Set(visibleGestures.map(\.id)).intersection(selection)
    }

    // MARK: - 选择

    func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    func selectAllVisible() {
        selection = Set(visibleGestures.map(\.id))
    }

    func clearSelection() {
        selection.removeAll()
    }

    // MARK: - 增删改

    func beginCreate(kind: GestureKind = .mouse) {
        // 新建时自动预填当前作用域——这是参考界面里最省事的一点
        switch kind {
        case .mouse:
            var gesture = Gesture(name: "新建鼠标手势",
                                  trigger: .rightButton,
                                  action: .window(.minimize),
                                  scopeID: selectedScopeID)
            gesture.path = PathRecognizer.normalize([CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)])
            editingGesture = gesture
        case .trackpad:
            // 触摸板手势预填最常用的「3 指轻点」——比空白起步好改
            editingGesture = Gesture.trackpadGesture(name: "新建触摸板手势",
                                                     spec: .tap(fingers: 3),
                                                     action: .window(.minimize),
                                                     scopeID: selectedScopeID)
        case .shortcut:
            // 快捷键没有轨迹也没有手指数，只有"还没设的那个键"等用户录
            editingGesture = Gesture.shortcut(name: "新建快捷键",
                                              hotkey: nil,
                                              action: .window(.minimize),
                                              scopeID: selectedScopeID)
        }
        isCreatingGesture = true
    }

    func beginEdit(_ gesture: Gesture) {
        editingGesture = gesture
        isCreatingGesture = false
    }

    func commitEditing(_ gesture: Gesture) {
        if isCreatingGesture {
            store.add(gesture)
        } else {
            store.update(gesture)
        }
        editingGesture = nil
        isCreatingGesture = false
    }

    func deleteSelected() {
        let ids = selectionInView
        guard !ids.isEmpty else { return }
        store.delete(ids: ids)
        selection.subtract(ids)
        showToast("已删除 \(ids.count) 条手势")
    }

    func setEnabledForSelection(_ enabled: Bool) {
        let ids = selectionInView
        guard !ids.isEmpty else { return }
        store.setEnabled(enabled, ids: ids)
        showToast(enabled ? "已启用 \(ids.count) 条" : "已禁用 \(ids.count) 条")
    }

    func duplicateSelected() {
        let ids = selectionInView
        guard !ids.isEmpty else { return }
        store.duplicate(ids: ids)
        clearSelection()
        showToast("已复制 \(ids.count) 条")
    }

    // MARK: - 备份 / 恢复

    /// 备份整机配置：全部手势 + 作用域 + 设置，一个文件装走
    func backupConfig() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BoxMouse-配置备份-\(Self.timestamp()).json"
        panel.title = "备份配置"
        panel.message = "包含全部手势（含各作用域）、触摸板手势和设置。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.backupData().write(to: url, options: .atomic)
            showToast("已备份 \(store.gestures.count) 条手势与设置")
        } catch {
            showToast("备份失败：\(error.localizedDescription)")
        }
    }

    /// 恢复配置 = 用备份**整体替换**当前配置，先确认再动手
    func restoreConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "恢复配置"
        panel.message = "选择一份 BoxMouse 配置备份"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            // 先解析不落盘：把"要覆盖成什么"算出来再问，比空口一句"确定吗"有用
            let preview = try store.previewRestore(data)
            guard confirmRestore(preview: preview, fileName: url.lastPathComponent) else { return }
            let report = try store.restore(from: data)
            clearSelection()
            // 恢复后原来的作用域多半已经不存在了：不切回全局的话，
            // 列表会按一个已经不存在的 scopeID 过滤，显示成空列表（像丢了数据）
            selectedScopeID = store.globalScope.id
            var text = "已恢复 \(report.gestures) 条手势、\(report.scopes) 个作用域"
            text += report.settingsRestored ? "与设置" : "（该备份不含设置，已保留当前设置）"
            showToast(text)
        } catch {
            showToast("恢复失败：\(error.localizedDescription)")
        }
    }

    private func confirmRestore(preview: RestorePreview, fileName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "恢复「\(fileName)」？"
        var lines = [
            "备份含 \(preview.gestureCount) 条手势、\(preview.scopeCount) 个作用域"
                + (preview.hasSettings ? "，以及一份设置。" : "（不含设置）。"),
            "当前 \(store.gestures.count) 条手势、\(store.scopes.count) 个作用域会被全部替换。"
        ]
        if preview.formatVersion < GestureArchive.currentFormatVersion {
            lines.append("这是旧版备份（格式 v\(preview.formatVersion)），设置不会被动。")
        }
        lines.append("覆盖前会自动存一份当前配置的快照到配置文件夹，可从「打开配置文件夹」找回。")
        alert.informativeText = lines.joined(separator: "\n\n")

        // 破坏性操作：把「取消」做成默认按钮，误按 Return 不会毁掉配置
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let proceed = alert.addButton(withTitle: "恢复")
        proceed.keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    // MARK: - 提示条

    func showToast(_ text: String) {
        toastWorkItem?.cancel()
        toast = text
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.toast = nil }
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
    }
}
