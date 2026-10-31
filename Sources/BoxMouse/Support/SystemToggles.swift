import AppKit
import ApplicationServices
import Combine
import CoreFoundation
import CoreGraphics

// ============================================================
// 三个「系统开关」：隐藏桌面图标 / 显示隐藏文件 / 锁定键盘
//
// 都搬自 BoxDock（那边已经踩过一轮），所以注释里保留了当时的结论。
//
// 共同点：**真相在系统里，不在我们的设置文件里**。所以三项都不持久化，
// 每次浮窗显示时现场读一遍：用户可能在别处改过（Finder 自己的显示选项、
// 系统把事件 tap 掐掉）。存一份副本只会让界面和事实打架。
// ============================================================

// MARK: - 跑外部命令

enum SystemShell {
    /// 只在「必须重启 Finder」这种场景用。参数全是你自己写的常量，不拼用户输入。
    @discardableResult
    static func run(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 不阻塞主线程的版本。`killall Finder` 要等 Finder 真的退完才返回（约 0.5~1s），
    /// 在浮窗的开关回调里同步等会让整个面板卡一下。
    static func runInBackground(_ path: String, _ arguments: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            run(path, arguments)
        }
    }
}

// MARK: - 隐藏桌面图标

/// 切换 Finder 的 CreateDesktop 偏好。
///
/// 关掉后 Finder 不再在桌面铺图标（桌面只剩壁纸），**文件本身一个都不动**，
/// 全在 ~/Desktop 原地——所以敢把这个开关做成一键往返。
///
/// 不调 `defaults` 子进程：直接写偏好域。子进程那一套在这个键上出过
/// 「写着成功、Finder 不认」的问题，而且多一层进程就多一次失败可能。
enum SystemDesktopIcons {
    private static let domain = "com.apple.finder" as CFString
    private static let key = "CreateDesktop" as CFString

    /// 桌面图标当前是否处于隐藏状态。
    /// 键不存在 = 从没动过 = 显示中（CreateDesktop 的缺省值是 true）。
    static var isHidden: Bool {
        guard let value = CFPreferencesCopyAppValue(key, domain) else { return false }
        return (value as? Bool) == false
    }

    static func setHidden(_ hidden: Bool) {
        CFPreferencesSetAppValue(key, NSNumber(value: !hidden), domain)
        CFPreferencesAppSynchronize(domain)
        // Finder 被杀后 launchd 自动拉起，重读偏好即生效。
        SystemShell.runInBackground("/usr/bin/killall", ["Finder"])
    }
}

// MARK: - 显示隐藏文件

/// 切换 com.apple.finder 域的 AppleShowAllFiles。
///
/// 🔴 踩坑实录：这个键**不属于全局域**。写成 NSGlobalDomain（哪怕用
/// `defaults write -g` 这条「官方推荐」路子），defaults 命令读着是 true，
/// Finder 自己却不认——它只查自己的域。正确姿势与
/// `defaults write com.apple.finder AppleShowAllFiles` 一致。
enum SystemHiddenFiles {
    private static let domain = "com.apple.finder" as CFString
    private static let key = "AppleShowAllFiles" as CFString

    /// 隐藏文件当前是否处于可见状态。
    /// 键不存在 = 从没动过 = 不可见。历史遗留的全局域值做只读兜底。
    static var isShown: Bool {
        if let value = CFPreferencesCopyAppValue(key, domain) {
            return (value as? Bool) == true
        }
        if let value = CFPreferencesCopyValue(key,
                                              kCFPreferencesAnyApplication,
                                              kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) {
            return (value as? Bool) == true
        }
        return false
    }

    static func setShown(_ shown: Bool) {
        CFPreferencesSetAppValue(key, NSNumber(value: shown), domain)
        CFPreferencesAppSynchronize(domain)
        // Finder 重启后重读偏好，与隐藏桌面图标共用同一套重启逻辑
        SystemShell.runInBackground("/usr/bin/killall", ["Finder"])
    }
}

// MARK: - 锁定键盘

/// 用 CGEventTap 在系统事件源头吞掉所有键盘事件。
///
/// 原理：在 HID 层挂一个事件 tap，命中 keyDown / keyUp / flagsChanged 时
/// 回调返回 nil——事件被吞掉，不会传给任何应用，键盘等于「断线」。
/// 鼠标/触控板事件不在掩码里，完全不受影响，所以锁定期间仍能点浮窗把开关关掉。
///
/// 安全性（为什么锁不死人）：
///   1. tap 挂在我们的进程上，进程一死（崩溃/被杀/退出）tap 自动拆除，
///      键盘立刻恢复——不存在「应用没了键盘还锁着」的状态；
///   2. 应用退出时主动 unlock 双保险；
///   3. 系统若因超时/用户输入临时禁用 tap，回调里重新启用。
///
/// 权限：HID 级事件 tap 需要「辅助功能」授权（TCC）。未授权时
/// CGEventTapCreate 会失败或 tap 静默失效，所以开关打开前先查
/// AXIsProcessTrusted，未授权走系统授权引导，开关诚实回弹。
enum SystemKeyboardLock {
    private static var eventTap: CFMachPort?
    private static var runLoopSource: CFRunLoopSource?

    static var isLocked: Bool { eventTap != nil }

    static func isAccessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// 查询辅助功能授权；prompt = true 时让系统弹「BoxMouse 想要控制你的电脑」引导框。
    static func checkAccessibility(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 返回是否真的锁上了。未授权时返回 false，调用方应回弹开关。
    @discardableResult
    static func setLocked(_ locked: Bool) -> Bool {
        if locked { return lock() }
        unlock()
        return true
    }

    private static func lock() -> Bool {
        guard eventTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        // kCGHIDEventTap / kCGHeadInsertEventTap / kCGEventTapOptionDefault
        // 这组 C 常量在 Swift 里的成员名不稳定，直接用原始值构造，
        // 语义以注释为准（0 = HID 层 / 头部插入 / 可吞事件）。
        guard let location = CGEventTapLocation(rawValue: 0),
              let placement = CGEventTapPlacement(rawValue: 0),
              let options = CGEventTapOptions(rawValue: 0),
              let tap = CGEvent.tapCreate(tap: location,
                                          place: placement,
                                          options: options,
                                          eventsOfInterest: mask,
                                          callback: keyboardCallback,
                                          userInfo: nil) else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        runLoopSource = source
        eventTap = tap
        return true
    }

    static func unlock() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        CFMachPortInvalidate(tap)
        runLoopSource = nil
        eventTap = nil
    }

    // 事件回调。@convention(c) 闭包不能捕获上下文，只能摸静态成员——
    // 这里读 eventTap 静态属性没问题。
    fileprivate static let keyboardCallback: CGEventTapCallBack = { _, type, event, _ in
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // 被系统临时禁用就重新启用，否则锁会「静默失效」
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        default:
            return nil  // 吞掉：键盘事件到此为止
        }
    }
}

// MARK: - 界面状态

/// 浮窗里的三个系统开关。由 `MenuBarController` 持有，每次显示浮窗前 `refresh()`。
@MainActor
final class SystemTogglesModel: ObservableObject {
    @Published private(set) var hideDesktopIcons = false
    @Published private(set) var showHiddenFiles = false
    @Published private(set) var keyboardLocked = false
    /// 锁键盘因为缺「辅助功能」授权没真正生效，行内要换成授权提示
    @Published private(set) var keyboardAuthNeeded = false

    /// 从系统现场读一遍。三项都很轻（两次偏好读取 + 一个静态判断）。
    func refresh() {
        hideDesktopIcons = SystemDesktopIcons.isHidden
        showHiddenFiles = SystemHiddenFiles.isShown
        keyboardLocked = SystemKeyboardLock.isLocked
        if !keyboardLocked { keyboardAuthNeeded = false }
    }

    func setDesktopIconsHidden(_ hidden: Bool) {
        hideDesktopIcons = hidden                       // 先落界面，Finder 重启在后台
        SystemDesktopIcons.setHidden(hidden)
    }

    func setHiddenFilesShown(_ shown: Bool) {
        showHiddenFiles = shown
        SystemHiddenFiles.setShown(shown)
    }

    /// 想锁却没授权时**不锁**，开关回弹并亮出授权提示。
    func setKeyboardLocked(_ locked: Bool) {
        guard locked else {
            SystemKeyboardLock.setLocked(false)
            keyboardLocked = false
            keyboardAuthNeeded = false
            return
        }
        if SystemKeyboardLock.isAccessibilityGranted() {
            keyboardAuthNeeded = false
            keyboardLocked = SystemKeyboardLock.setLocked(true)
        } else {
            // 弹系统授权引导框；授权完成后回来再拨一次开关即可生效
            _ = SystemKeyboardLock.checkAccessibility(prompt: true)
            keyboardLocked = false
            keyboardAuthNeeded = true
        }
    }
}
