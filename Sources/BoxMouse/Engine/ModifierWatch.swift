import AppKit

/// 修饰键的实时状态。
///
/// 为什么需要它：
/// 鼠标手势的修饰键可以直接从「那一次鼠标事件的 flags」里读——事件自带修饰键状态，
/// 一定准。但触摸板手势没有事件可读：触点帧里只有坐标，没有 flags。
/// 只能去查「当前键盘状态」，而这里有一个致命的不确定性：
///
///   ① Fn（地球仪键）在 `CGEventSource.flagsState(.combinedSessionState)` 里
///      **不一定可见**。Apple 把它标注成 hardware flag（0x800000），但不同
///      系统版本上状态查询经常读不到。
///      于是「按住 Fn + 三指滑动」的手势永远匹配不上：
///      配置是 {fn}，实测解出来是 {}，而修饰键是**全等**匹配，直接判死。
///      症状就是「触摸板操作无效」——识别其实成功了，只是候选一个都匹配不上。
///   ② 用合成事件去验证 ① 是没用的：合成事件不改硬件状态，测了也白测。
///
/// 所以这里做三层兜底，任何一层能看见就算看见：
///   1. `flagsState` —— 常规路径，⌘⌥⌃⇧ 靠它就够了
///   2. `keyState(key: kVK_Function)` —— 直接问 Fn 这个键的硬件状态
///   3. 全局 + 本地 `flagsChanged` 事件流 —— 真实按键必经这条路，顺手把 Fn 记下来
///
/// 第 3 层还有个附带好处：它对**所有**修饰键都准，不只是 Fn。
final class ModifierWatch {

    static let shared = ModifierWatch()

    /// kVK_Function —— Fn / 地球仪键的虚拟键码
    private static let functionKeyCode: CGKeyCode = 63

    private let lock = NSLock()
    /// 最近一次 flagsChanged 事件带回来的完整 flags
    private var lastEventFlags: CGEventFlags = []
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    /// 装上监听。App 启动时调一次即可，重复调用安全。
    func start() {
        lock.lock()
        let already = globalMonitor != nil || localMonitor != nil
        lock.unlock()
        guard !already else { return }

        // 后台时 global 有效；前台时 local 有效。两条一起上，覆盖全部情况。
        let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.record(event.modifierFlags)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.record(event.modifierFlags)
            return event
        }

        lock.lock()
        globalMonitor = global
        localMonitor = local
        lock.unlock()
    }

    private func record(_ flags: NSEvent.ModifierFlags) {
        // NSEvent.ModifierFlags 的位与 CGEventFlags 一一对应（function ↔ maskSecondaryFn
        // 都是 0x800000），可以直接当 CGEventFlags 用。
        lock.lock()
        lastEventFlags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        lock.unlock()
    }

    /// 当前按住的修饰键集合。触摸板路径用它来匹配候选。
    func current() -> Set<ModifierKey> {
        var set = ModifierKey.set(from: CGEventSource.flagsState(.combinedSessionState))

        // ② 直接问 Fn 的硬件状态
        if CGEventSource.keyState(.combinedSessionState, key: Self.functionKeyCode) {
            set.insert(.fn)
        }

        // ③ 事件流里记住的那一份
        lock.lock()
        let eventFlags = lastEventFlags
        lock.unlock()
        if !eventFlags.intersection([.maskSecondaryFn]).isEmpty {
            set.insert(.fn)
        }
        return set
    }

    /// 给界面/日志看的可读形式
    func currentDescription() -> String {
        ModifierKey.describe(current())
    }
}
