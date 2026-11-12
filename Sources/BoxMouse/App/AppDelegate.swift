import AppKit
import Combine
import SwiftUI

// ============================================================
// 应用委托：窗口 + 主菜单 + 菜单栏图标 + 引擎生命周期
//
// 用 NSWindow + NSHostingView 而不是 SwiftUI App：
//   · SwiftPM 可执行 target 里 @main 的 App 生命周期会把 --selftest 这类
//     参数处理挤到 SwiftUI 的启动流程里，不好拦；
//   · 家族其他项目（BoxPaste / BoxWallpaper）都是这个结构，保持一致。
// ============================================================

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow?
    private var model: AppModel!
    private var menuBar: MenuBarController?
    private var dockCancellable: AnyCancellable?
    private var tabCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = GestureStore()
        let engine = GestureEngine(store: store)
        let trackpad = TrackpadEngine()
        let model = AppModel(store: store, engine: engine, trackpad: trackpad)
        self.model = model

        // 激活策略必须在建窗口之前定下来：先建窗口再 setActivationPolicy(.accessory)
        // 会留下"没有 Dock 图标、窗口还抢不到焦点"的怪状态。
        applyDockVisibility(hideDock: store.settings.hideDockIcon)

        // 修饰键实时监听：触摸板手势没有事件可读，只能查状态，
        // 状态查询对 Fn 不一定准（见 ModifierWatch 的说明）。必须在 bootstrap 之前装上。
        ModifierWatch.shared.start()

        model.bootstrap()
        buildMainMenu()
        buildWindow(model: model)

        // 菜单栏图标是隐藏 Dock 之后的唯一入口，窗口建好就立刻挂上
        model.openWindow = { [weak self] tab in
            self?.showMainWindow(tab: tab)
        }
        menuBar = MenuBarController(model: model)
        observeDockSetting(store: store)
        observeTab(model: model)

        // 🔴 静默启动：不弹主界面、不激活应用。
        // 开机自启 / 重开应用时窗口直接怼到脸上很打扰，尤其是登录后用一堆
        // 应用同时启动，焦点被抢走会打断用户正在干的事。
        // 窗口在 buildWindow 里已经建好并居中，只是不显示；
        // 之后点菜单栏图标（或 Dock 图标）会走 showMainWindow 亮相。
        // 这里也不能调 NSApp.activate：那等于把当前应用踢到后台。
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关窗不退出：手势引擎要在后台继续工作
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow(tab: nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 键盘锁的双保险：tap 随进程消失本来就会拆，但主动放一次更符合直觉，
        // 也避免"退出动画期间键盘还哑着"的错觉。
        SystemKeyboardLock.unlock()
        model?.shutdown()
    }

    // MARK: - 窗口

    private func buildWindow(model: AppModel) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 950, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "BoxMouse"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // 用 contentMinSize 而不是 minSize：关于页只有几行字，900×560 的下限
        // 会让窗口缩不下去，看着像"调不了大小"。下限按标签页切换，见 observeTab。
        window.contentMinSize = Self.panelMinSize
        window.center()
        window.contentView = NSHostingView(rootView: RootView(model: model))
        // 不 makeKeyAndOrderFront：静默启动，等用户从菜单栏图标进来时再显示
        self.window = window
    }

    /// 菜单栏浮窗与 Dock 图标点击都走这里：把窗口捞回来并切到指定页
    private func showMainWindow(tab: MainTab?) {
        if let tab { model?.selectedTab = tab }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Dock 图标

    /// `LSUIElement` 只决定启动那一刻的样子，运行时的显隐只能靠激活策略。
    /// .accessory = 只有菜单栏没有 Dock 图标；.regular = 两者都有。
    private func applyDockVisibility(hideDock: Bool) {
        let policy: NSApplication.ActivationPolicy = hideDock ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)

        // 实测：setActivationPolicy 会让应用被动失活（焦点直接交还给上一个应用，
        // 菜单栏也换成别人的名字）。同步里当场 activate 会被随后的失活流程盖掉，
        // 必须挪到下一拍 runloop 再抢一次，窗口还要 orderFrontRegardless 才回到最前。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, window.isVisible else { return }
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKey()
        }
    }

    /// 列表页要有足够宽度摆下多列，关于页只有几行字——下限跟着标签页走，
    /// 否则用户在关于页怎么拖都缩不下去。
    private static let panelMinSize = NSSize(width: 900, height: 560)
    private static let aboutMinSize = NSSize(width: 520, height: 420)

    private func observeTab(model: AppModel) {
        tabCancellable = model.$selectedTab
            .removeDuplicates()
            .sink { [weak self] tab in
                guard let window = self?.window else { return }
                let limit = tab == .about ? Self.aboutMinSize : Self.panelMinSize
                window.contentMinSize = limit
                // contentMinSize 只约束「下一次」缩放：在关于页把窗口拖到 520 宽，
                // 切回列表页它不会自己长回去，顶部标签栏直接被窗口右沿切掉，
                // 「权限」「关于」两个入口就点不到了。这里主动兜一次。
                Self.grow(window, toAtLeast: limit)
            }
    }

    /// 把窗口撑到不小于 `minimum`（内容区尺寸），顶边不动，只往右下扩。
    private static func grow(_ window: NSWindow, toAtLeast minimum: NSSize) {
        let needed = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimum)).size
        var frame = window.frame
        guard frame.width < needed.width || frame.height < needed.height else { return }

        let width = max(frame.width, needed.width)
        let height = max(frame.height, needed.height)
        // AppKit 原点在左下：高度变大时 origin.y 要减掉差值，视觉上顶边才不动
        frame.origin.y -= height - frame.height
        frame.size = NSSize(width: width, height: height)

        // 别把窗口顶出屏幕下沿——屏幕小的时候宁可保持原样
        if let visible = window.screen?.visibleFrame, frame.minY < visible.minY {
            frame.origin.y = visible.minY
        }
        window.setFrame(frame, display: true, animate: false)
    }

    private func observeDockSetting(store: GestureStore) {
        dockCancellable = store.$settings
            .map(\.hideDockIcon)
            .removeDuplicates()
            .dropFirst()   // 启动时已经按存档应用过一次
            .sink { [weak self] hidden in
                self?.applyDockVisibility(hideDock: hidden)
            }
    }

    // MARK: - 主菜单

    /// 程序化建最小主菜单：没有它文本框按不出 ⌘C / ⌘V / ⌘A。
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BoxMouse",
                        action: #selector(showAbout),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BoxMouse", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BoxMouse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showAbout() {
        showMainWindow(tab: .about)
    }
}
