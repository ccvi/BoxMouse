import Foundation
import CoreGraphics

// ============================================================
// 数据模型
//
// 设计取舍：
//   · 触发器做成**扁平枚举**而不是带关联值的 enum——UI 里 Picker 直接用
//     CaseIterable 铺开，JSON 也更好读、好手改。
//   · 动作做成「一个 kind + 若干可选载荷」的扁平结构。比 enum 带关联值啰嗦，
//     但导入导出时字段稳定，改一个动作类型不会让旧配置文件解码失败。
// ============================================================

/// 鼠标键触发方式
///
/// 只放**鼠标键**。修饰键不是触发方式，而是叠加在鼠标手势上的条件
/// （按住 Fn + 右键画一笔），见 `ModifierKey`。
///
/// 早期版本把 Fn/⌘/⌥/⌃/⇧ 也做成了触发方式，语义是"按住某个修饰键移动指针画"。
/// 那是错的：Fn + 移动指针在系统里是滚动，⌘ + 拖拽是选文件，都抢不过系统，
/// 而且用户想要的是"修饰键 + 鼠标手势"这种组合。老配置由 `Gesture` 的解码器迁移。
enum GestureTrigger: String, Codable, CaseIterable, Identifiable {
    case rightButton
    case middleButton
    case sideButton

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rightButton:  return "右键绘制"
        case .middleButton: return "中键绘制"
        case .sideButton:   return "侧键绘制"
        }
    }

    /// 短名，用在表格「触发键」列
    var shortName: String {
        switch self {
        case .rightButton:  return "右键"
        case .middleButton: return "中键"
        case .sideButton:   return "侧键"
        }
    }
}

/// 修饰键：跟鼠标手势**叠加**使用的条件
///
/// 空集合 = 「无」，即裸右键/中键/侧键手势。
/// 一个手势的修饰键集合必须与按下鼠标那一刻的修饰键状态**完全一致**才命中，
/// 这样「右键画 L」和「⌘ + 右键画 L」可以是两条互不干扰的手势。
///
/// 顺序按用户给的来：Fn、Command、Option、Control、Shift。
enum ModifierKey: String, Codable, CaseIterable, Identifiable, Hashable {
    case fn
    case command
    case option
    case control
    case shift

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn:      return "Fn"
        case .command: return "Command"
        case .option:  return "Option"
        case .control: return "Control"
        case .shift:   return "Shift"
        }
    }

    /// 界面上画在按钮里的符号。键盘上印的就是这些，比写全名省地方。
    var symbol: String {
        switch self {
        case .fn:      return "fn"
        case .command: return "⌘"
        case .option:  return "⌥"
        case .control: return "⌃"
        case .shift:   return "⇧"
        }
    }

    /// 组合展示用（表格列、摘要）：⌘⇧
    var compact: String {
        switch self {
        case .fn:      return "fn"
        default:       return symbol
        }
    }

    var flag: CGEventFlags {
        switch self {
        case .fn:      return .maskSecondaryFn
        case .command: return .maskCommand
        case .option:  return .maskAlternate
        case .control: return .maskControl
        case .shift:   return .maskShift
        }
    }

    /// 只在判定时关心的那几位。CGEvent 的 flags 里还混着 .maskNonCoalesced 之类的杂位，
    /// 直接比较整个 flags 永远不等。
    static let relevantFlags: CGEventFlags = [.maskSecondaryFn, .maskCommand,
                                              .maskAlternate, .maskControl, .maskShift]

    /// 从一次鼠标事件的 flags 里解出按住的修饰键集合
    static func set(from flags: CGEventFlags) -> Set<ModifierKey> {
        let masked = flags.intersection(relevantFlags)
        return Set(allCases.filter { !masked.intersection($0.flag).isEmpty })
    }

    /// 按固定顺序把一组修饰键拼成 "⌘⇧" 这样的字符串
    static func describe(_ set: Set<ModifierKey>) -> String {
        // 顺序固定，否则 Set 遍历顺序在不同进程里不一样，表格会闪
        allCases.filter { set.contains($0) }.map(\.compact).joined()
    }

    /// 老配置里的 trigger 值（.fn/.command/...）转成修饰键，用于迁移
    init?(legacyTrigger raw: String) {
        switch raw {
        case "fn":      self = .fn
        case "command": self = .command
        case "option":  self = .option
        case "control": self = .control
        case "shift":   self = .shift
        default:        return nil
        }
    }
}

/// 手势的输入设备
///
/// 两类手势用同一套「名称 / 动作 / 作用域」，只有"怎么触发"不同：
/// 鼠标手势靠画轨迹，触摸板手势靠手指数 + 动作类型。
enum GestureKind: String, Codable {
    case mouse
    case trackpad
    /// 全局快捷键：不画轨迹、也不碰触摸板，按一下组合键就执行动作。
    /// 复用 Gesture 这条流水线（作用域、动作、启停、列表）比另起一套模型省事得多，
    /// 代价是 path / trigger / trackpad 这几个字段对它没意义，留默认值不管。
    case shortcut
}

/// 列表的「触发方式」筛选。
///
/// 早先这里按鼠标键筛（右键绘制 / 中键绘制 / 侧键绘制）。那只覆盖得了鼠标手势一类，
/// 触摸板手势和快捷键在列表里根本筛不出来——而它们恰恰是越来越多的一类。
/// 改成按触发方式分组，三类各占一格，跟「添加」菜单里的分类也对得上。
enum GestureKindFilter: String, CaseIterable, Identifiable {
    case all
    case mouse
    case trackpad
    case shortcut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:      return "全部"
        case .mouse:    return "鼠标手势"
        case .trackpad: return "触摸板手势"
        case .shortcut: return "快捷键"
        }
    }

    /// 对应要筛的 kind；`all` 不筛。
    var kind: GestureKind? {
        switch self {
        case .all:      return nil
        case .mouse:    return .mouse
        case .trackpad: return .trackpad
        case .shortcut: return .shortcut
        }
    }
}

/// 触摸板手势的形态
enum TrackpadPattern: String, Codable, CaseIterable, Identifiable {
    /// N 指同时落下再抬起，几乎不移动
    case tap
    /// N 指朝同一方向平移
    case swipe
    /// 两指靠拢
    case pinchIn
    /// 两指张开
    case pinchOut
    /// 单指在触控板上画出一条轨迹（与鼠标手势同一套识别）
    case path

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tap:      return "轻点"
        case .swipe:    return "滑动"
        case .pinchIn:  return "捏合（缩小）"
        case .pinchOut: return "张开（放大）"
        case .path:     return "画轨迹"
        }
    }

    var symbolName: String {
        switch self {
        case .tap:      return "hand.tap"
        case .swipe:    return "hand.draw"
        case .pinchIn:  return "arrow.down.right.and.arrow.up.left"
        case .pinchOut: return "arrow.up.left.and.arrow.down.right"
        case .path:     return "scribble"
        }
    }

    /// 捏合类手势固定两指，手指数不可选
    var fixesTwoFingers: Bool {
        self == .pinchIn || self == .pinchOut
    }

    /// 单指只允许「轻点」和「画轨迹」：单指在触控板上就是移动指针，
    /// 滑动和捏合都不可能由一根手指完成，放开只会制造永不适用的配置。
    var requiresMultipleFingers: Bool {
        self != .tap && self != .path
    }
}

/// 滑动方向
enum SwipeDirection: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .up:    return "向上"
        case .down:  return "向下"
        case .left:  return "向左"
        case .right: return "向右"
        }
    }

    /// 放进短描述里用：4 指上滑
    var shortName: String {
        switch self {
        case .up:    return "上滑"
        case .down:  return "下滑"
        case .left:  return "左滑"
        case .right: return "右滑"
        }
    }

    var symbolName: String {
        switch self {
        case .up:    return "arrow.up"
        case .down:  return "arrow.down"
        case .left:  return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}

/// 一条触摸板手势的"触发条件"
struct TrackpadSpec: Codable, Hashable {
    var fingers: Int
    var pattern: TrackpadPattern
    /// 只有 .swipe 用得到
    var direction: SwipeDirection?
    /// 只有 .path 用得到：归一化后的模板轨迹（与 Gesture.path 同一套算法）
    var path: [PathPoint]?
    /// 原始采样点。跟 Gesture.rawPath 一个用途：以后调识别算法时能重算老配置
    var rawPath: [PathPoint]?

    static func tap(fingers: Int) -> TrackpadSpec {
        TrackpadSpec(fingers: fingers, pattern: .tap, direction: nil)
    }

    static func swipe(fingers: Int, _ direction: SwipeDirection) -> TrackpadSpec {
        TrackpadSpec(fingers: fingers, pattern: .swipe, direction: direction)
    }

    static func pinchIn() -> TrackpadSpec {
        TrackpadSpec(fingers: 2, pattern: .pinchIn, direction: nil)
    }

    static func pinchOut() -> TrackpadSpec {
        TrackpadSpec(fingers: 2, pattern: .pinchOut, direction: nil)
    }

    /// 把这个组合修平：单指只剩轻点，捏合固定两指。
    /// 编辑器切来切去会留下矛盾字段，保存前统一过一遍。
    func sanitized() -> TrackpadSpec {
        var copy = self
        if copy.pattern.fixesTwoFingers {
            copy.fingers = 2
            copy.direction = nil
        } else if copy.pattern == .path {
            // 画轨迹固定单指：多指轨迹的重心轨迹不是用户画的东西
            copy.fingers = 1
            copy.direction = nil
        } else if copy.fingers <= 1 {
            copy.fingers = 1
            copy.pattern = .tap
            copy.direction = nil
        } else if copy.pattern == .swipe {
            copy.direction = copy.direction ?? .up
        } else {
            copy.direction = nil
        }
        if copy.pattern != .swipe { copy.direction = nil }
        if copy.pattern != .path { copy.path = nil; copy.rawPath = nil }
        return copy
    }

    /// 表格、浮窗里的短描述：`3 指轻点` / `4 指上滑`
    var summary: String {
        switch pattern {
        case .tap:      return "\(fingers) 指轻点"
        case .swipe:    return "\(fingers) 指\(direction?.shortName ?? "滑动")"
        case .pinchIn:  return "两指捏合"
        case .pinchOut: return "两指张开"
        case .path:     return "画轨迹"
        }
    }
}

/// 浏览器操作。
///
/// 全部走各浏览器通用的 ⌘ 组合键（Chrome / Edge / Safari / Arc / Firefox 都认），
/// 不去区分具体是哪个浏览器——同一个手势在三个浏览器里都能用，比"按浏览器分一堆选项"实用。
enum BrowserOp: String, Codable, CaseIterable, Identifiable {
    case back
    case forward
    case reload
    case newTab
    case closeTab
    case reopenTab
    case nextTab
    case previousTab
    case copyURL

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .back:       return "后退"
        case .forward:    return "前进"
        case .reload:     return "刷新页面"
        case .newTab:     return "新建标签页"
        case .closeTab:   return "关闭标签页"
        case .reopenTab:  return "恢复已关闭的标签页"
        case .nextTab:    return "下一个标签页"
        case .previousTab: return "上一个标签页"
        case .copyURL:    return "复制当前页链接"
        }
    }

    var shortName: String { displayName }

    /// 触发的按键组合。keyCode 是 macOS 虚拟键码。
    ///
    /// 「复制当前页链接」没有单键快捷键，浏览器里复制地址要两步：⌘L 选中地址栏，再 ⌘C 复制，
    /// 所以这一项单独返回两步。
    var keyCombos: [KeyCombo] {
        let command = CGEventFlags.maskCommand.rawValue
        let control = CGEventFlags.maskControl.rawValue
        let shift = CGEventFlags.maskShift.rawValue

        switch self {
        case .back:        return [KeyCombo(keyCode: 33, flags: command, display: "⌘[")]
        case .forward:     return [KeyCombo(keyCode: 30, flags: command, display: "⌘]")]
        case .reload:      return [KeyCombo(keyCode: 15, flags: command, display: "⌘R")]
        case .newTab:      return [KeyCombo(keyCode: 17, flags: command, display: "⌘T")]
        case .closeTab:    return [KeyCombo(keyCode: 13, flags: command, display: "⌘W")]
        case .reopenTab:   return [KeyCombo(keyCode: 17, flags: command | shift, display: "⌘⇧T")]
        case .nextTab:     return [KeyCombo(keyCode: 48, flags: control, display: "⌃⇥")]
        case .previousTab: return [KeyCombo(keyCode: 48, flags: control | shift, display: "⌃⇧⇥")]
        case .copyURL:
            return [KeyCombo(keyCode: 37, flags: command, display: "⌘L"),
                    KeyCombo(keyCode: 8, flags: command, display: "⌘C")]
        }
    }
}

/// 动作类型
enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case keystroke
    case openApp
    case openURL
    case media
    case window
    case browser

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keystroke: return "键盘快捷键"
        case .openApp:   return "打开应用"
        case .openURL:   return "打开 URL"
        case .media:     return "媒体键"
        case .window:    return "窗口操作"
        case .browser:   return "浏览器操作"
        }
    }

    /// 用在表格「动作」列的动词前缀
    var prefix: String {
        switch self {
        case .keystroke: return "快捷键"
        case .openApp:   return "打开应用"
        case .openURL:   return "打开 URL"
        case .media:     return "媒体键"
        case .window:    return "窗口操作"
        case .browser:   return "浏览器操作"
        }
    }

    var symbolName: String {
        switch self {
        case .keystroke: return "command"
        case .openApp:   return "app.badge"
        case .openURL:   return "link"
        case .media:     return "playpause"
        case .window:    return "macwindow"
        case .browser:   return "safari"
        }
    }
}

/// 媒体键（对应 NX_KEYTYPE_*）
enum MediaKey: String, Codable, CaseIterable, Identifiable {
    case playPause
    case next
    case previous
    case volumeUp
    case volumeDown
    case mute

    var id: String { rawValue }

    /// NX_KEYTYPE 数值。这几个常量在 IOKit 的 ev_keymap.h 里，
    /// Swift 拿不到（C 宏不是符号），只能按数值抄过来。
    var nxKeyType: Int32 {
        switch self {
        case .playPause:  return 16   // NX_KEYTYPE_PLAY
        case .next:       return 17   // NX_KEYTYPE_NEXT
        case .previous:   return 18   // NX_KEYTYPE_PREVIOUS
        case .volumeUp:   return 0    // NX_KEYTYPE_SOUND_UP
        case .volumeDown: return 1    // NX_KEYTYPE_SOUND_DOWN
        case .mute:       return 7    // NX_KEYTYPE_MUTE
        }
    }

    var displayName: String {
        switch self {
        case .playPause:  return "播放 / 暂停"
        case .next:       return "下一曲"
        case .previous:   return "上一曲"
        case .volumeUp:   return "音量 +"
        case .volumeDown: return "音量 −"
        case .mute:       return "静音"
        }
    }

    /// 表格里用的短标识，跟参考界面的 playPause 写法保持一致
    var shortName: String {
        switch self {
        case .playPause:  return "playPause"
        case .next:       return "next"
        case .previous:   return "previous"
        case .volumeUp:   return "volumeUp"
        case .volumeDown: return "volumeDown"
        case .mute:       return "mute"
        }
    }
}

/// 窗口操作
///
/// 最大化与还原是两个独立动作，不是"切换"。
/// 手势场景里不能给用户一个"按一下变、再按一下变回来"的动作——
/// 画同一个手势时窗口当前是什么状态不可知，结果就不可预测。
enum WindowOp: String, Codable, CaseIterable, Identifiable {
    case close
    case minimize
    case maximize
    case restore
    case fullScreen
    /// 平铺：贴左半屏 / 贴右半屏
    case leftHalf
    case rightHalf
    /// 满屏：铺满可用区（菜单栏和 Dock 之外），**不进全屏空间**
    case fillScreen
    /// 贴左 3/5（宽度占屏 3/5，上下满高）。
    /// 比半屏宽一点、比 2/3 窄一点，是给「主窗口 + 一个窄参考窗」准备的中间档。
    case leftThreeFifths
    /// 贴左 2/3（宽度占屏 2/3，上下满高）
    case leftTwoThirds
    /// 贴右 2/3（与左 2/3 同宽，贴右边）
    case rightTwoThirds
    /// 贴左 3/4 / 贴右 3/4（宽度占屏 3/4，上下满高）
    case leftThreeFourths
    case rightThreeFourths
    /// 左上 1/4（左上角，宽高各占一半）
    case topLeftQuarter
    /// 居中：宽度各取可用区的 2/3 或 3/4，左右居中、上下满高
    case centerTwoThirds
    case centerThreeFourths

    var id: String { rawValue }

    /// 老配置里 `.zoom` 是"最大化 / 还原"切换，拆开后按"最大化"处理：
    /// 语义上最接近用户当初的意图，而且重复触发不会卡在错误状态。
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "zoom", let op = WindowOp(rawValue: "maximize") {
            self = op
            return
        }
        guard let op = WindowOp(rawValue: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "未知的窗口操作：\(raw)"))
        }
        self = op
    }

    var displayName: String {
        switch self {
        case .close:      return "关闭窗口"
        case .minimize:   return "最小化窗口"
        case .maximize:   return "最大化窗口"
        case .restore:    return "还原窗口"
        case .fullScreen: return "切换全屏"
        case .leftHalf:   return "左半屏"
        case .rightHalf:  return "右半屏"
        case .fillScreen: return "窗口满屏"
        case .leftThreeFifths:    return "左 3/5"
        case .leftTwoThirds:      return "左 2/3"
        case .rightTwoThirds:     return "右 2/3"
        case .leftThreeFourths:   return "左 3/4"
        case .rightThreeFourths:  return "右 3/4"
        case .topLeftQuarter:     return "左上 1/4"
        case .centerTwoThirds:    return "居中 2/3"
        case .centerThreeFourths: return "居中 3/4"
        }
    }

    var shortName: String {
        switch self {
        case .close:      return "close"
        case .minimize:   return "minimize"
        case .maximize:   return "maximize"
        case .restore:    return "restore"
        case .fullScreen: return "fullScreen"
        case .leftHalf:   return "leftHalf"
        case .rightHalf:  return "rightHalf"
        case .fillScreen: return "fillScreen"
        case .leftThreeFifths:    return "left3of5"
        case .leftTwoThirds:      return "left2of3"
        case .rightTwoThirds:     return "right2of3"
        case .leftThreeFourths:   return "left3of4"
        case .rightThreeFourths:  return "right3of4"
        case .topLeftQuarter:     return "topLeftQuarter"
        case .centerTwoThirds:    return "center2of3"
        case .centerThreeFourths: return "center3of4"
        }
    }

    /// 是不是"设定几何位置"这一类动作。
    ///
    /// 平铺/居中不走缩放按钮，也不看窗口当前状态——每次都直接算出一个目标矩形，
    /// 所以不受 AX 缺少"是否已最大化"属性的限制，重复触发结果稳定。
    var isTiling: Bool {
        switch self {
        case .leftHalf, .rightHalf, .fillScreen,
             .leftThreeFifths,
             .leftTwoThirds, .rightTwoThirds, .leftThreeFourths, .rightThreeFourths,
             .topLeftQuarter, .centerTwoThirds, .centerThreeFourths:
            return true
        default:
            return false
        }
    }
}

/// 键位组合
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt16
    var flags: UInt64        // CGEventFlags.rawValue
    var display: String      // 存一份显示文本，避免解码后还要反查键名

    static let empty = KeyCombo(keyCode: 0, flags: 0, display: "未设置")

    /// 只有这几个修饰键参与快捷键匹配。
    /// Fn / CapsLock / 左右修饰键的细分位在不同键盘和布局下会飘，算进去会让快捷键时灵时不灵。
    static let shortcutModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    /// 不产生字符的键：F1–F20、方向键、Home/End/PageUp/PageDown/Delete。
    /// 单独按这些键没有输入含义，可以安全地拿来做全局快捷键。
    static let functionKeyCodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100,    // F1–F8
        101, 109, 103, 111, 105, 107, 113,     // F9–F15
        106, 64, 79, 80, 90,                   // F16–F20
        123, 124, 125, 126,                    // ← → ↓ ↑
        115, 119, 116, 121,                    // Home End PageUp PageDown
        117                                     // Forward Delete
    ]

    /// 实际按下了几个修饰键（只数参与匹配的那四个）。
    var shortcutModifierCount: Int {
        let modifiers = CGEventFlags(rawValue: flags).intersection(Self.shortcutModifiers)
        var count = 0
        if modifiers.contains(.maskControl)   { count += 1 }
        if modifiers.contains(.maskAlternate) { count += 1 }
        if modifiers.contains(.maskShift)     { count += 1 }
        if modifiers.contains(.maskCommand)   { count += 1 }
        return count
    }

    /// 能不能当全局快捷键用。
    ///
    /// 三条限制，每条都对应一种"配完之后整台机器不对劲"：
    /// 1. 至少一个修饰键，或者不产生字符的功能键 —— 裸字母会把全系统这个键吞掉。
    /// 2. **修饰键最多两个** —— ⌘⇧K 这类两键组合要用；再往上（三个、四个）
    ///    手指已经很难按，而且和系统/应用自带快捷键大面积重叠，收益低于误伤。
    /// 3. （见调用方）作用域内不许撞键。
    var isUsableAsShortcut: Bool {
        guard shortcutModifierCount <= 2 else { return false }
        let modifiers = CGEventFlags(rawValue: flags).intersection(Self.shortcutModifiers)
        return !modifiers.isEmpty || Self.functionKeyCodes.contains(keyCode)
    }
}

/// 录制组合键期间的状态位。
///
/// 编辑器里"按下要录的键"和"按下触发快捷键"在系统看来是同一件事：都是 keyDown。
/// 用户给新快捷键录一个**已经存在**的组合键时，那条旧动作会当场执行——
/// 旧动作要是「关闭窗口」，用户的窗口就在录制过程中被关掉了。
/// 所以录制期间引擎整体放行键盘事件，一个字都别拦。
enum ShortcutCapture {
    static var isRecording = false
}

/// 一个动作的完整描述。字段按 kind 取用，未用到的留空。
struct GestureAction: Codable, Hashable {
    var kind: ActionKind
    var keyCombo: KeyCombo?
    var appPath: String?
    var appName: String?
    var urlString: String?
    var mediaKey: MediaKey?
    var windowOp: WindowOp?
    /// 浏览器操作。老配置里没有这个键 → 解码成 nil，不影响旧文件。
    var browserOp: BrowserOp?

    static func keystroke(_ combo: KeyCombo) -> GestureAction {
        GestureAction(kind: .keystroke, keyCombo: combo)
    }

    static func openApp(path: String, name: String) -> GestureAction {
        GestureAction(kind: .openApp, appPath: path, appName: name)
    }

    static func openURL(_ string: String) -> GestureAction {
        GestureAction(kind: .openURL, urlString: string)
    }

    static func media(_ key: MediaKey) -> GestureAction {
        GestureAction(kind: .media, mediaKey: key)
    }

    static func window(_ op: WindowOp) -> GestureAction {
        GestureAction(kind: .window, windowOp: op)
    }

    static func browser(_ op: BrowserOp) -> GestureAction {
        GestureAction(kind: .browser, browserOp: op)
    }

    /// 表格「动作」列的描述文本
    var summary: String {
        switch kind {
        case .keystroke:
            return "\(kind.prefix)：\(keyCombo?.display ?? "未设置")"
        case .openApp:
            return "\(kind.prefix)：\(appName ?? "未选择")"
        case .openURL:
            return "\(kind.prefix)：\(urlString ?? "未设置")"
        case .media:
            return "\(kind.prefix)：\(mediaKey?.shortName ?? "未设置")"
        case .window:
            return "\(kind.prefix)：\(windowOp?.shortName ?? "未设置")"
        case .browser:
            return "\(kind.prefix)：\(browserOp?.shortName ?? "未设置")"
        }
    }

    /// 编辑器里的校验：填不全的动作不该被保存
    var isValid: Bool {
        switch kind {
        case .keystroke: return keyCombo != nil && keyCombo?.display != "未设置"
        case .openApp:   return !(appPath ?? "").isEmpty
        case .openURL:   return !(urlString ?? "").isEmpty
        case .media:     return mediaKey != nil
        case .window:    return windowOp != nil
        case .browser:   return browserOp != nil
        }
    }
}

/// 作用域类型
enum ScopeKind: String, Codable {
    case global
    case app
    case group
}

/// 侧栏里的一个作用域条目：全局 / 单个应用 / 应用组
struct ScopeEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: ScopeKind
    var name: String
    /// 单应用条目放 1 个 bundle id；应用组放多个
    var bundleIDs: [String]

    static func global() -> ScopeEntry {
        ScopeEntry(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                   kind: .global, name: "全局", bundleIDs: [])
    }

    static func app(name: String, bundleID: String) -> ScopeEntry {
        ScopeEntry(id: UUID(), kind: .app, name: name, bundleIDs: [bundleID])
    }

    static func group(name: String, bundleIDs: [String]) -> ScopeEntry {
        ScopeEntry(id: UUID(), kind: .group, name: name, bundleIDs: bundleIDs)
    }

    var symbolName: String {
        switch kind {
        case .global: return "globe"
        case .app:    return "app.dashed"
        case .group:  return "square.stack.3d.up"
        }
    }

    /// 这个作用域是否覆盖指定 bundle id
    func covers(bundleID: String?) -> Bool {
        switch kind {
        case .global:
            return true
        case .app, .group:
            guard let bundleID else { return false }
            return bundleIDs.contains(bundleID)
        }
    }
}

/// 目标应用的判定方式
enum TargetMode: String, Codable, CaseIterable, Identifiable {
    case frontmost
    case underPointer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frontmost:    return "按键时的前台应用"
        case .underPointer: return "指针所在的应用"
        }
    }
}

/// 轨迹上的一个点（用 Double 而不是 CGPoint，JSON 更干净、跨版本稳定）
struct PathPoint: Codable, Hashable {
    var x: Double
    var y: Double

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }
}

/// 一条手势
struct Gesture: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var enabled: Bool
    /// 鼠标手势 or 触摸板手势
    var kind: GestureKind
    var trigger: GestureTrigger
    /// 跟触发起手时叠加按住的修饰键；空集合 = 「无」
    var modifiers: Set<ModifierKey>
    /// 触摸板手势的触发条件（kind == .trackpad 时有值）
    var trackpad: TrackpadSpec?
    /// 快捷键条目的按键（kind == .shortcut 时有值）
    var hotkey: KeyCombo?
    var action: GestureAction
    var scopeID: UUID
    /// 归一化后的模板轨迹（见 PathRecognizer.normalize）——比对时用这个
    var path: [PathPoint]
    /// 原始采样点（未归一化）。留着它的唯一目的：以后调识别算法时
    /// 能重新归一化老配置，不让用户的手势库因为一次算法改动全部失效。
    var rawPath: [PathPoint]?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String,
         enabled: Bool = true,
         kind: GestureKind = .mouse,
         trigger: GestureTrigger = .rightButton,
         modifiers: Set<ModifierKey> = [],
         trackpad: TrackpadSpec? = nil,
         hotkey: KeyCombo? = nil,
         action: GestureAction,
         scopeID: UUID,
         path: [PathPoint] = [],
         rawPath: [PathPoint]? = nil,
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.kind = kind
        self.trigger = trigger
        self.modifiers = modifiers
        self.trackpad = trackpad
        self.hotkey = hotkey
        self.action = action
        self.scopeID = scopeID
        self.path = path
        self.rawPath = rawPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 触摸板手势的便捷构造
    static func trackpadGesture(name: String,
                                spec: TrackpadSpec,
                                action: GestureAction,
                                scopeID: UUID) -> Gesture {
        Gesture(name: name, kind: .trackpad, trackpad: spec, action: action, scopeID: scopeID)
    }

    /// 快捷键条目的便捷构造
    static func shortcut(name: String,
                         hotkey: KeyCombo?,
                         action: GestureAction,
                         scopeID: UUID) -> Gesture {
        Gesture(name: name, kind: .shortcut, hotkey: hotkey, action: action, scopeID: scopeID)
    }

    /// 「怎么触发」的可读描述。表格、摘要共用。
    var triggerDescription: String {
        switch kind {
        case .trackpad:
            let base = trackpad?.summary ?? "触摸板"
            // 修饰键也要写出来：配了 fn 的「1 指轻点」和裸的「1 指轻点」是两条手势，
            // 表格里不显示修饰键，用户看到两行一样的「1 指轻点」根本分不清谁是谁。
            return modifiers.isEmpty ? base : "\(ModifierKey.describe(modifiers)) + \(base)"
        case .mouse:
            return modifiers.isEmpty
                ? trigger.shortName
                : "\(ModifierKey.describe(modifiers)) + \(trigger.shortName)"
        case .shortcut:
            // 快捷键的"触发方式"就是那个组合键本身
            return hotkey?.display ?? "未设置快捷键"
        }
    }

    // MARK: - 解码（含老配置迁移）

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, kind, trigger, modifiers, trackpad, action, scopeID
        case path, rawPath, hotkey, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        // 1.0.7 及以前没有 kind 字段，缺省一律当鼠标手势
        kind = try c.decodeIfPresent(GestureKind.self, forKey: .kind) ?? .mouse
        trackpad = try c.decodeIfPresent(TrackpadSpec.self, forKey: .trackpad)
        hotkey = try c.decodeIfPresent(KeyCombo.self, forKey: .hotkey)
        action = try c.decode(GestureAction.self, forKey: .action)
        scopeID = try c.decode(UUID.self, forKey: .scopeID)
        path = try c.decodeIfPresent([PathPoint].self, forKey: .path) ?? []
        rawPath = try c.decodeIfPresent([PathPoint].self, forKey: .rawPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()

        // 老版本把 Fn/⌘/⌥/⌃/⇧ 也当成触发方式（"按住某键移动指针画"）。
        // 现在它们是叠加条件，迁移成「右键绘制 + 该修饰键」：
        // 语义最接近用户当初的动作意图，而且右键仍然是能画的那个键。
        let rawTrigger = try c.decodeIfPresent(String.self, forKey: .trigger) ?? "rightButton"
        if let legacy = ModifierKey(legacyTrigger: rawTrigger) {
            trigger = .rightButton
            modifiers = [legacy]
        } else if let parsed = GestureTrigger(rawValue: rawTrigger) {
            trigger = parsed
            modifiers = try c.decodeIfPresent(Set<ModifierKey>.self, forKey: .modifiers) ?? []
        } else {
            throw DecodingError.dataCorruptedError(forKey: .trigger, in: c,
                                                   debugDescription: "未知的触发方式：\(rawTrigger)")
        }
    }
}
