import Foundation
import Combine
import AppKit

// ============================================================
// 配置存储
//
// 落地位置：~/Library/Application Support/BoxMouse/
//   gestures.json  —— 手势 + 作用域
//   settings.json  —— 全局设置
//
// 为什么拆两个文件：手势库会被外部编辑、纳入版本管理，改动频繁；
// 设置是本机偏好，写盘走 debounce。两者寿命不同，合成一个文件等于
// 改个滑块就要重写整份手势库。
//
// 但**备份**是另一回事：用户要的是"整机搬走/回到某一天"，
// 所以备份文件里两个都装，缺一个都不算完整配置。
// ============================================================

/// 全局设置
///
/// 手写 init(from:)：`JSONDecoder` 的合成解码遇到"文件里没有这个键"会直接抛
/// keyNotFound，而 `try?` 又把整份配置当坏的丢掉——等于每加一个字段，
/// 老用户升级一次配置就被清空。所以每个键都用 decodeIfPresent 回落到默认值。
struct BoxMouseSettings: Codable, Equatable {
    var engineEnabled: Bool = true
    /// 目标应用判定方式
    var targetMode: TargetMode = .frontmost
    /// 是否锁定按键那一刻的窗口（右键在手势过程中窗口可能变）
    var lockWindow: Bool = false
    /// 轨迹最短像素长度，低于它当成一次普通点击
    var minPathLength: Double = 18
    /// 绘制时屏幕上的笔迹颜色（十六进制）
    var trailColorHex: String = "#FF3B30"
    /// 笔迹粗细
    var trailWidth: Double = 3.0
    /// 绘制时是否在屏幕上显示轨迹
    var showTrail: Bool = true
    /// 触发手势时是否忽略 BoxMouse 自己的窗口
    var skipOwnWindow: Bool = true
    /// 多指触控（实验性，1.x 未接入引擎，开关置灰占位）
    var multiTouchEnabled: Bool = false
    /// 隐藏 Dock 图标：菜单栏常驻工具的常规做法，默认保留 Dock 图标
    var hideDockIcon: Bool = false
    /// 手势匹配成功后，在屏幕上提示动作名
    var showSuccessFeedback: Bool = true
    /// 画了手势但没匹配上任何一条时，提示「未识别手势」
    var showUnrecognizedFeedback: Bool = true

    // MARK: - 鼠标控制

    /// 鼠标增强总开关。
    ///
    /// 默认关：升级上来的用户不该一睁眼发现滚轮手感变了、侧键不画手势了。
    /// 想用的人自己去「鼠标」页打开，页面会明确写出当前状态。
    var mouseControlEnabled: Bool = false
    /// 平滑滚轮：把鼠标滚轮的「行滚动」转成带缓动的像素滚动。
    /// 触控板/妙控鼠标自带平滑与惯性，不走这条（否则会双重平滑）。
    var smoothScrollEnabled: Bool = false
    /// 平滑滚轮的力度倍率。1.0 = 标准，越大滚得越远。
    var smoothScrollStrength: Double = 1.0
    /// 滚轮反方向：垂直和水平都翻。
    var invertScrollEnabled: Bool = false
    /// 侧键（Forward / Back）按下时要执行的动作。
    ///
    /// **没有单独的模式开关**：配了动作就是「按下即执行」，没配就是老行为
    /// （按住侧键画轨迹）。理由很直接——三选一的模式让用户可以配出一堆
    /// 「选了动作但两个键都没设东西」的空状态，界面上还得多解释一遍谁覆盖谁。
    /// 现在一颗键一个开关，开关本身就是它自己的模式。
    var forwardButtonAction: GestureAction?
    /// Back 按键要执行的动作
    var backButtonAction: GestureAction?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case engineEnabled, targetMode, lockWindow, minPathLength
        case trailColorHex, trailWidth, showTrail, skipOwnWindow
        case multiTouchEnabled, hideDockIcon
        case showSuccessFeedback, showUnrecognizedFeedback
        case smoothScrollEnabled, smoothScrollStrength, invertScrollEnabled
        case forwardButtonAction, backButtonAction
        case mouseControlEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = BoxMouseSettings()
        engineEnabled = try container.decodeIfPresent(Bool.self, forKey: .engineEnabled) ?? fallback.engineEnabled
        targetMode = try container.decodeIfPresent(TargetMode.self, forKey: .targetMode) ?? fallback.targetMode
        lockWindow = try container.decodeIfPresent(Bool.self, forKey: .lockWindow) ?? fallback.lockWindow
        minPathLength = try container.decodeIfPresent(Double.self, forKey: .minPathLength) ?? fallback.minPathLength
        trailColorHex = try container.decodeIfPresent(String.self, forKey: .trailColorHex) ?? fallback.trailColorHex
        trailWidth = try container.decodeIfPresent(Double.self, forKey: .trailWidth) ?? fallback.trailWidth
        showTrail = try container.decodeIfPresent(Bool.self, forKey: .showTrail) ?? fallback.showTrail
        skipOwnWindow = try container.decodeIfPresent(Bool.self, forKey: .skipOwnWindow) ?? fallback.skipOwnWindow
        multiTouchEnabled = try container.decodeIfPresent(Bool.self, forKey: .multiTouchEnabled) ?? fallback.multiTouchEnabled
        hideDockIcon = try container.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? fallback.hideDockIcon
        showSuccessFeedback = try container.decodeIfPresent(Bool.self, forKey: .showSuccessFeedback)
            ?? fallback.showSuccessFeedback
        showUnrecognizedFeedback = try container.decodeIfPresent(Bool.self, forKey: .showUnrecognizedFeedback)
            ?? fallback.showUnrecognizedFeedback
        mouseControlEnabled = try container.decodeIfPresent(Bool.self, forKey: .mouseControlEnabled)
            ?? fallback.mouseControlEnabled
        smoothScrollEnabled = try container.decodeIfPresent(Bool.self, forKey: .smoothScrollEnabled)
            ?? fallback.smoothScrollEnabled
        smoothScrollStrength = try container.decodeIfPresent(Double.self, forKey: .smoothScrollStrength)
            ?? fallback.smoothScrollStrength
        invertScrollEnabled = try container.decodeIfPresent(Bool.self, forKey: .invertScrollEnabled)
            ?? fallback.invertScrollEnabled
        forwardButtonAction = try container.decodeIfPresent(GestureAction.self, forKey: .forwardButtonAction)
        backButtonAction = try container.decodeIfPresent(GestureAction.self, forKey: .backButtonAction)
    }
}

extension BoxMouseSettings {
    /// 鼠标控制（滚轮 / 侧键动作）有没有任何一项在生效。
    ///
    /// 这一组功能独立于「手势引擎」总开关：用户完全可能只想用平滑滚轮，
    /// 不想要任何手势。事件 tap 只要还有一项在生效就得挂着。
    ///
    /// 总开关关掉时一律视为不生效——不然用户把总开关一关，滚轮却还在被改写，
    /// 「开关」就成了摆设。
    var mouseControlActive: Bool {
        guard mouseControlEnabled else { return false }
        return smoothScrollEnabled || invertScrollEnabled
            || forwardButtonAction != nil || backButtonAction != nil
    }

    /// 事件 tap 需不需要挂着
    var needsEventTap: Bool { engineEnabled || mouseControlActive }
}

/// 备份文件结构
///
/// v1：只有 gestures + scopes（旧版「导出手势」，还只导当前作用域）
/// v2：加了 appVersion 与 settings，变成**整机配置**快照
///
/// 解码全部走 decodeIfPresent：备份文件是用户会拿文本编辑器打开、改名、
/// 手改的那种东西，合成解码只要缺一个键就整份丢掉，太脆了。
struct GestureArchive: Codable {
    static let currentFormatVersion = 2

    var formatVersion: Int = GestureArchive.currentFormatVersion
    var exportedAt: Date = Date()
    var app: String = "BoxMouse"
    /// 备份时的 BoxMouse 版本，出问题时一眼能看出是哪个版本存的
    var appVersion: String?
    var gestures: [Gesture]
    var scopes: [ScopeEntry]
    /// v1 备份里没有这一项 → nil，恢复时保留本机现有设置
    var settings: BoxMouseSettings?

    init(gestures: [Gesture],
         scopes: [ScopeEntry],
         settings: BoxMouseSettings? = nil,
         appVersion: String? = nil) {
        self.gestures = gestures
        self.scopes = scopes
        self.settings = settings
        self.appVersion = appVersion
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, exportedAt, app, appVersion, gestures, scopes, settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        exportedAt = try container.decodeIfPresent(Date.self, forKey: .exportedAt) ?? Date()
        app = try container.decodeIfPresent(String.self, forKey: .app) ?? "BoxMouse"
        appVersion = try container.decodeIfPresent(String.self, forKey: .appVersion)
        settings = try container.decodeIfPresent(BoxMouseSettings.self, forKey: .settings)
        // 手势与作用域是这份文件的**全部意义**，缺了就真不是备份
        guard let gestures = try container.decodeIfPresent([Gesture].self, forKey: .gestures),
              let scopes = try container.decodeIfPresent([ScopeEntry].self, forKey: .scopes) else {
            throw ConfigArchiveError.notArchive
        }
        self.gestures = gestures
        self.scopes = scopes
    }
}

/// 备份文件解不开时的可读原因
enum ConfigArchiveError: LocalizedError {
    case notArchive
    case tooNew(Int)

    var errorDescription: String? {
        switch self {
        case .notArchive:
            return "文件不是有效的 BoxMouse 配置备份"
        case .tooNew(let version):
            return "这份备份由更新版本的 BoxMouse 生成（格式 v\(version)），请先升级再恢复"
        }
    }
}

/// 恢复前的预览：先只看不写，好把"覆盖什么"讲清楚再动手
struct RestorePreview {
    var gestureCount: Int
    var scopeCount: Int
    var hasSettings: Bool
    var formatVersion: Int
}

/// 恢复结果
struct RestoreReport {
    var gestures: Int
    var scopes: Int
    var settingsRestored: Bool
    /// 覆盖前自动存下的当前配置快照（文件名，空 = 没存成功）
    var snapshotName: String?
}

@MainActor
final class GestureStore: ObservableObject {

    @Published private(set) var gestures: [Gesture] = []
    @Published private(set) var scopes: [ScopeEntry] = []
    @Published var settings: BoxMouseSettings = BoxMouseSettings() {
        didSet {
            // 读取阶段不要回写，否则每次启动都会把默认值盖回文件
            if !isLoadingSettings && settings != oldValue { saveSettings() }
        }
    }

    private var isLoadingSettings = false

    /// 引擎要在每次手势库变化后重建候选索引
    let didChangeLibrary = PassthroughSubject<Void, Never>()

    private let directory: URL
    private let gesturesURL: URL
    private let settingsURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BoxMouse", isDirectory: true)
        self.directory = base
        self.gesturesURL = base.appendingPathComponent("gestures.json")
        self.settingsURL = base.appendingPathComponent("settings.json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
    }

    // MARK: - 读写

    private struct Library: Codable {
        var gestures: [Gesture]
        var scopes: [ScopeEntry]
    }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? Data(contentsOf: gesturesURL),
           let library = try? decoder.decode(Library.self, from: data) {
            // 有原始点就按当前算法重算一遍：识别算法升级过之后，
            // 老配置不用用户手工重建。
            gestures = GestureStore.renormalize(library.gestures)
            scopes = library.scopes
            ensureGlobalScope()
        } else {
            seedDefaults()
        }

        if let data = try? Data(contentsOf: settingsURL),
           let decoded = try? decoder.decode(BoxMouseSettings.self, from: data) {
            isLoadingSettings = true
            settings = decoded
            isLoadingSettings = false
        }

        didChangeLibrary.send()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let library = Library(gestures: gestures, scopes: scopes)
        if let data = try? encoder.encode(library) {
            try? data.write(to: gesturesURL, options: .atomic)
        }
        didChangeLibrary.send()
    }

    /// 把手势模板的原始点按**当前**算法重算一遍。
    ///
    /// 鼠标轨迹和触摸板「画轨迹」的模板都存了 rawPath，识别算法升级过之后
    /// 老配置不用用户手工重建。读盘和恢复备份都走这里，保证两条路径不会分叉。
    static func renormalize(_ source: [Gesture]) -> [Gesture] {
        source.map { gesture in
            var copy = gesture
            if let raw = gesture.rawPath, raw.count > 1 {
                copy.path = PathRecognizer.normalize(raw.map { $0.cgPoint })
            }
            if copy.trackpad?.pattern == .path,
               let raw = copy.trackpad?.rawPath, raw.count > 1 {
                copy.trackpad?.path = PathRecognizer.normalize(raw.map { $0.cgPoint })
            }
            return copy
        }
    }

    /// 还没落盘的那次设置写入
    private var settingsSaveWork: DispatchWorkItem?

    /// 设置写盘是 **debounce 0.5 秒**的。
    ///
    /// 拖颜色选择器 / 粗细滑块时，settings 每秒变几十次；以前每次都
    /// 「编码 + 原子写盘」（原子写 = 临时文件 + rename），等于持续抖磁盘。
    /// 攒 0.5 秒只写最后一次；退出前由 AppModel 调 flushSettings() 兜底。
    private func saveSettings() {
        settingsSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.writeSettingsNow()
        }
        settingsSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 立刻落盘（退出前 / 需要同步确认时调用）
    func flushSettings() {
        settingsSaveWork?.cancel()
        settingsSaveWork = nil
        writeSettingsNow()
    }

    private func writeSettingsNow() {
        settingsSaveWork = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    // MARK: - 作用域

    var globalScope: ScopeEntry {
        scopes.first { $0.kind == .global } ?? ScopeEntry.global()
    }

    private func ensureGlobalScope() {
        if !scopes.contains(where: { $0.kind == .global }) {
            scopes.insert(ScopeEntry.global(), at: 0)
        }
    }

    func scope(id: UUID) -> ScopeEntry? {
        scopes.first { $0.id == id }
    }

    func scopeName(id: UUID) -> String {
        scope(id: id)?.name ?? "全局"
    }

    /// 新增「指定应用」作用域；同一个 bundle id 不重复添加
    @discardableResult
    func addAppScope(name: String, bundleID: String) -> ScopeEntry {
        if let existing = scopes.first(where: { $0.kind == .app && $0.bundleIDs == [bundleID] }) {
            return existing
        }
        let entry = ScopeEntry.app(name: name, bundleID: bundleID)
        scopes.append(entry)
        save()
        return entry
    }

    @discardableResult
    func addGroupScope(name: String, bundleIDs: [String]) -> ScopeEntry {
        let entry = ScopeEntry.group(name: name, bundleIDs: bundleIDs)
        scopes.append(entry)
        save()
        return entry
    }

    /// 改写已有应用组的名称与成员。
    ///
    /// 以前建组之后成员就定死了，侧栏只能"移除作用域"整个删掉——想加一个应用
    /// 或去掉一个，只能重建组并把它名下手势重新指过去。这个入口补的就是这件事。
    /// 只对 `.group` 生效：单个应用作用域改 bundle id 没有意义（那是另一个应用了）。
    @discardableResult
    func updateGroupScope(id: UUID, name: String, bundleIDs: [String]) -> Bool {
        guard let index = scopes.firstIndex(where: { $0.id == id && $0.kind == .group }) else {
            return false
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        scopes[index].name = trimmed.isEmpty ? scopes[index].name : trimmed
        scopes[index].bundleIDs = bundleIDs
        save()
        return true
    }

    func removeScope(id: UUID) {
        guard let entry = scope(id: id), entry.kind != .global else { return }
        scopes.removeAll { $0.id == id }
        // 该作用域下的手势一并删除，否则会变成"孤儿"永远显示不出来
        gestures.removeAll { $0.scopeID == id }
        save()
    }

    func gestureCount(scopeID: UUID) -> Int {
        gestures.filter { $0.scopeID == scopeID }.count
    }

    // MARK: - 手势增删改

    func add(_ gesture: Gesture) {
        gestures.append(gesture)
        save()
    }

    func update(_ gesture: Gesture) {
        guard let index = gestures.firstIndex(where: { $0.id == gesture.id }) else { return }
        var copy = gesture
        copy.updatedAt = Date()
        gestures[index] = copy
        save()
    }

    func delete(ids: Set<UUID>) {
        gestures.removeAll { ids.contains($0.id) }
        save()
    }

    func setEnabled(_ enabled: Bool, ids: Set<UUID>) {
        for index in gestures.indices where ids.contains(gestures[index].id) {
            gestures[index].enabled = enabled
            gestures[index].updatedAt = Date()
        }
        save()
    }

    func duplicate(ids: Set<UUID>) {
        let copies = gestures.filter { ids.contains($0.id) }.map { gesture -> Gesture in
            var copy = gesture
            copy.id = UUID()
            copy.name = gesture.name + " 副本"
            copy.createdAt = Date()
            copy.updatedAt = Date()
            return copy
        }
        gestures.append(contentsOf: copies)
        save()
    }

    /// 只保留候选：启用 + 触发键匹配 + 修饰键完全一致 + 作用域覆盖当前应用
    ///
    /// 修饰键用**全等**而不是包含：用户在「右键画 L」之外再建一条「⌘ + 右键画 L」，
    /// 两条必须互不干扰。用包含判断的话，裸右键那条会连 ⌘ 的情况也吞掉。
    func candidates(trigger: GestureTrigger,
                    modifiers: Set<ModifierKey> = [],
                    bundleID: String?) -> [Gesture] {
        gestures.filter { gesture in
            guard gesture.kind == .mouse,
                  gesture.enabled,
                  gesture.trigger == trigger,
                  gesture.modifiers == modifiers else { return false }
            guard let entry = scope(id: gesture.scopeID) else { return false }
            return entry.covers(bundleID: bundleID)
        }
    }

    /// 命中的快捷键条目，没有命中返回 nil。
    ///
    /// 比较范围只有「键码 + ⌘⌥⌃⇧」，其余标志位不参与（见 KeyCombo.shortcutModifiers）。
    /// 作用域规则和手势一致：应用级优先于全局，这样同一个组合键可以在某个应用里另作他用。
    func shortcutMatch(keyCode: Int64, flags: CGEventFlags, bundleID: String?) -> Gesture? {
        let wanted = flags.intersection(KeyCombo.shortcutModifiers)
        var globalFallback: Gesture?

        for gesture in gestures {
            guard gesture.kind == .shortcut,
                  gesture.enabled,
                  let hotkey = gesture.hotkey,
                  hotkey.isUsableAsShortcut,
                  Int64(hotkey.keyCode) == keyCode,
                  CGEventFlags(rawValue: hotkey.flags).intersection(KeyCombo.shortcutModifiers) == wanted,
                  let entry = scope(id: gesture.scopeID),
                  entry.covers(bundleID: bundleID) else { continue }

            if entry.kind != .global { return gesture }
            if globalFallback == nil { globalFallback = gesture }
        }
        return globalFallback
    }

    /// 触摸板手势的候选：启用 + 触发条件命中 + 修饰键完全一致 + 作用域覆盖
    ///
    /// 排序和应用作用域的优先级一致：非全局的排前面，这样同一个「3 指轻点」
    /// 在某个应用里另有定义时，应用级那条会先命中。
    func trackpadCandidates(event: TrackpadEvent,
                            modifiers: Set<ModifierKey> = [],
                            bundleID: String?) -> [Gesture] {
        let matched = gestures.filter { gesture in
            guard gesture.kind == .trackpad,
                  gesture.enabled,
                  gesture.modifiers == modifiers,
                  let spec = gesture.trackpad,
                  // 画轨迹必须带修饰键：裸单指在触控板上就是移动指针，
                  // 每一段指针移动都会被攒成轨迹并触发动作，等于把触控板废掉。
                  // 编辑器已经强制选择，这里再挡一道，老配置也不会出事。
                  !(spec.pattern == .path && gesture.modifiers.isEmpty),
                  Self.matches(spec: spec, event: event) else { return false }
            guard let entry = scope(id: gesture.scopeID) else { return false }
            return entry.covers(bundleID: bundleID)
        }
        return matched.sorted { lhs, rhs in
            let lhsGlobal = scope(id: lhs.scopeID)?.kind == .global
            let rhsGlobal = scope(id: rhs.scopeID)?.kind == .global
            if lhsGlobal != rhsGlobal { return !lhsGlobal }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    /// 触发条件是否命中。捏合只看张开/合拢的方向，不看比例大小——
    /// 比例每个触控板、每个人都不一样，用它做匹配会让同一手势时灵时不灵。
    private static func matches(spec: TrackpadSpec, event: TrackpadEvent) -> Bool {
        switch event {
        case let .tap(fingers):
            return spec.pattern == .tap && spec.fingers == fingers
        case let .swipe(fingers, direction):
            return spec.pattern == .swipe && spec.fingers == fingers && spec.direction == direction
        case let .pinch(ratio):
            switch spec.pattern {
            case .pinchIn:  return ratio < 1
            case .pinchOut: return ratio > 1
            default:        return false
            }
        case let .path(points):
            guard spec.pattern == .path,
                  let template = spec.path, template.count >= 2 else { return false }
            // 轨迹匹配与鼠标手势同一套算法：先归一化再打分。
            // 模板存的就是归一化结果；事件里的点还要过一遍归一化。
            let normalized = PathRecognizer.normalize(points)
            guard !normalized.isEmpty else { return false }
            return PathRecognizer.score(normalized, template) >= PathRecognizer.matchThreshold
        }
    }

    /// 这只鼠标键上是否有任何启用的手势（决定要不要吞掉鼠标事件）
    func hasEnabledGesture(trigger: GestureTrigger) -> Bool {
        gestures.contains { $0.kind == .mouse && $0.enabled && $0.trigger == trigger }
    }

    // MARK: - 备份 / 恢复

    /// 配置文件夹（给「打开配置文件夹」和快照用）
    var configDirectory: URL { directory }

    /// 当前版本号，写进备份头里方便排查
    static var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 备份：**整机配置**——全部手势、全部作用域、设置。
    ///
    /// 以前叫「导出手势」，只导当前作用域，用户想整机搬走就得一个作用域
    /// 导一次文件，还得手动把 settings.json 一起拷。备份的意义是"完整"，
    /// 缺一块就不叫备份了。
    func backupData() throws -> Data {
        let archive = GestureArchive(gestures: gestures,
                                     scopes: scopes,
                                     settings: settings,
                                     appVersion: GestureStore.appVersion)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    private func decodeArchive(_ data: Data) throws -> GestureArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let archive = try? decoder.decode(GestureArchive.self, from: data) else {
            throw ConfigArchiveError.notArchive
        }
        guard archive.formatVersion <= GestureArchive.currentFormatVersion else {
            throw ConfigArchiveError.tooNew(archive.formatVersion)
        }
        return archive
    }

    /// 只解析不落盘：先拿到"要覆盖成什么"，才好让用户确认。
    func previewRestore(_ data: Data) throws -> RestorePreview {
        let archive = try decodeArchive(data)
        return RestorePreview(gestureCount: archive.gestures.count,
                              scopeCount: archive.scopes.count,
                              hasSettings: archive.settings != nil,
                              formatVersion: archive.formatVersion)
    }

    /// 恢复：用备份**整体替换**当前配置。
    ///
    /// 和「导入」的本质区别：导入是往库里塞（会合并、会重名叠加），
    /// 恢复是回到备份那一刻的状态——所以必须先删干净再装。
    /// 破坏性操作，调用方要先让用户确认；这里额外留一份覆盖前的快照兜底。
    @discardableResult
    func restore(from data: Data) throws -> RestoreReport {
        let archive = try decodeArchive(data)

        // 先把现在这份存下来：恢复错了还能找回来，比任何提示都实在
        let snapshotName = writeRestoreSnapshot()

        scopes = archive.scopes
        ensureGlobalScope()

        // 备份里可能引用了不存在的作用域（手改过、或 v1 文件里作用域被裁过），
        // 落到全局，别留成侧栏里永远看不见的孤儿。
        let knownScopes = Set(scopes.map(\.id))
        let fallbackScope = globalScope.id
        var seenIDs = Set<UUID>()
        gestures = GestureStore.renormalize(archive.gestures).map { gesture in
            var copy = gesture
            if !knownScopes.contains(copy.scopeID) { copy.scopeID = fallbackScope }
            // id 撞车（手改文件）会让选中/删除按错条目
            if seenIDs.contains(copy.id) { copy.id = UUID() }
            seenIDs.insert(copy.id)
            return copy
        }

        // v1 备份没有设置 → 保留本机现有设置，别凭空重置用户的偏好
        if let restored = archive.settings {
            settings = restored
            flushSettings()
        }

        save()
        return RestoreReport(gestures: gestures.count,
                             scopes: scopes.count,
                             settingsRestored: archive.settings != nil,
                             snapshotName: snapshotName)
    }

    // MARK: - 覆盖前快照

    private static let snapshotPrefix = "恢复前快照-"

    /// 恢复前把当前配置写一份到配置文件夹，最多留 3 份。
    private func writeRestoreSnapshot() -> String? {
        guard let data = try? backupData() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = GestureStore.snapshotPrefix + formatter.string(from: Date()) + ".json"
        let url = directory.appendingPathComponent(name)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        pruneSnapshots(keep: 3)
        return name
    }

    /// 只留最近几份快照：恢复是个低频动作，攒几十份反而没人愿意进那个文件夹
    private func pruneSnapshots(keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix(GestureStore.snapshotPrefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
        for url in files.dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - 出厂手势

    /// 首次启动的示例手势。故意选「一眼能看懂」的动作，用户照着改就行。
    func seedDefaults() {
        let global = ScopeEntry.global()
        scopes = [global]

        func gesture(_ name: String,
                     _ trigger: GestureTrigger,
                     _ action: GestureAction,
                     _ waypoints: [(Double, Double)]) -> Gesture {
            let points = waypoints.map { CGPoint(x: $0.0, y: $0.1) }
            return Gesture(name: name,
                           trigger: trigger,
                           action: action,
                           scopeID: global.id,
                           path: PathRecognizer.normalize(points),
                           rawPath: points.map { PathPoint($0) })
        }

        // 形状必须两两可区分：归一化会抹掉位置和大小，
        // 两条"只差一个平移"的 L 形（如下→右 与 上→右）会互相抢，
        // 自检里 testMatchingAgainstSeeds 就是拦这个的。
        gestures = [
            gesture("窗口最小化", .rightButton, .window(.minimize),
                    [(0, 0), (0, 1), (1, 1)]),                       // 下 → 右
            gesture("关闭窗口", .rightButton, .window(.close),
                    [(0, 0), (1, 0), (1, 1)]),                       // 右 → 下
            gesture("Mission Control", .rightButton,
                    .keystroke(KeyCombo(keyCode: 126, flags: CGEventFlags.maskControl.rawValue, display: "⌃↑")),
                    [(0, 1), (0, -1)]),                              // 上
            gesture("Play / Pause", .rightButton, .media(.playPause),
                    [(-1, 0), (1, 0)]),                              // 右
            gesture("Open Safari", .rightButton,
                    .openApp(path: "/Applications/Safari.app", name: "Safari"),
                    [(-1, 1), (1, -1)]),                             // 右上斜线
            gesture("全屏切换", .middleButton, .window(.fullScreen),
                    [(0, 0), (1, 0), (1, -1)]),                      // 右 → 上
        ]
        save()
    }
}
