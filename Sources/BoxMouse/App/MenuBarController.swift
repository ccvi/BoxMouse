import AppKit
import Combine
import SwiftUI

// ============================================================
// 菜单栏图标 + 浮窗
//
// 为什么用 NSStatusItem + 自绘面板，而不是 SwiftUI 的 MenuBarExtra：
// 主界面是 NSWindow + NSHostingView 撑起来的（见 AppDelegate），
// MenuBarExtra 只能在 SwiftUI App 生命周期里用。
//
// 为什么不用 NSPopover：
// popover 必定要画一个指向状态项的三角箭头（约 11pt 高），系统还会在
// 菜单栏底下再留一道，实测浮窗顶边离菜单栏 27pt。NSPopover 没有关掉
// 箭头的公开开关，所以改成自己定位的无边框面板——顶边直接取状态项
// 窗口的 minY，与菜单栏严丝合缝。
//
// 三个坑：
//   1. **不激活就点不动**。面板不激活 app 的话，里面的开关和按钮第一次
//      点只会"激活窗口"，第二次才生效。显示前显式 NSApp.activate。
//   2. **点别处要收起**。非激活面板点其他应用时不一定 resignKey，光靠
//      通知靠不住，补一个全局鼠标监听兜底（只在面板可见时挂，别常驻）。
//   3. **圆角靠 SwiftUI 裁**。窗口底色透明 + hasShadow，阴影仍由窗口
//      服务器按内容形状生成，所以圆角处不会出现方块阴影。
// ============================================================

/// 浮窗面板：能成为 key（Esc 才有人接），但不参与主窗口身份
private final class MenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// 浮窗外壳：给内容加圆角和一道细边，其余交给 MenuBarPanel
private struct MenuPanelRoot: View {
    let model: AppModel
    let onClose: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }

    var body: some View {
        MenuBarPanel(model: model, onClose: onClose)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

@MainActor
final class MenuBarController: NSObject {

    /// 浮窗内容宽度（MenuBarPanel 内部按这个宽排版）
    private static let panelWidth: CGFloat = 300

    private let model: AppModel
    private let statusItem: NSStatusItem
    private let hosting: NSHostingController<MenuPanelRoot>
    private let panel: MenuPanel

    /// 全局鼠标监听：面板可见时才挂，收起就摘
    private var globalClickMonitor: Any?
    /// 面板显示时刻。刚显示的那一瞬间系统可能递一个 resignKey 过来，得忽略
    private var shownAt: Date = .distantPast
    private var cancellables = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.hosting = NSHostingController(rootView: MenuPanelRoot(model: model, onClose: {}))
        self.panel = MenuPanel(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 320),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered,
                               defer: false)
        super.init()
        // onClose 要回指 self，只能等 super.init 之后再把真正的 rootView 换进去
        hosting.rootView = MenuPanelRoot(model: model, onClose: { [weak self] in self?.closePanel() })
        configurePanel()
        configureStatusItem()
        observeEngineState()
    }

    // MARK: - 状态项

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = MenuBarIcon.make()
        button.imagePosition = .imageOnly
        button.toolTip = "BoxMouse 鼠标手势"
        button.target = self
        button.action = #selector(togglePanel(_:))
        // 只认抬起：按下即弹会让"按住看一眼"变得别扭
        button.sendAction(on: [.leftMouseUp])
    }

    /// 引擎关掉时把图标压暗，"它到底在不在工作"不用点开就知道
    private func observeEngineState() {
        model.store.$settings
            .map(\.engineEnabled)
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.statusItem.button?.appearsDisabled = !enabled
            }
            .store(in: &cancellables)
    }

    // MARK: - 面板

    private func configurePanel() {
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.isFloatingPanel = true
        panel.level = .statusBar          // 与菜单栏同级，不会被别的窗口压住
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false   // 由我们自己决定何时收起
        panel.isMovable = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = hosting

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(panelDidResignKey),
                                               name: NSWindow.didResignKeyNotification,
                                               object: panel)
    }

    @objc private func togglePanel(_ sender: Any?) {
        if panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        resizePanel()
        positionPanel(anchor: buttonWindow)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        shownAt = Date()
        installGlobalMonitor()
    }

    private func closePanel() {
        removeGlobalMonitor()
        panel.orderOut(nil)
    }

    /// 由系统信号触发的收起：刚显示那一瞬间的杂音要放过
    private func closePanelAutomatically() {
        guard panel.isVisible,
              Date().timeIntervalSince(shownAt) > 0.15 else { return }
        closePanel()
    }

    @objc private func panelDidResignKey(_ note: Notification) {
        // 掉 key 不等于"用户点了别处"——激活主窗口、系统的短暂抢焦点都会触发。
        // 等一下再看：这会儿已经不是 key 了才算真走了。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow else { return }
            self.closePanelAutomatically()
        }
    }

    /// 内容高度随「有没有触发记录 / 有没有权限提示」变化，每次显示前重新量
    private func resizePanel() {
        let height = measureHeight()
        panel.setContentSize(NSSize(width: Self.panelWidth, height: height))
        // ⚠️ 量高度时把内容视图临时撑到了 4000 高，这里必须摁回窗口内容大小。
        // 否则内容视图比窗口高，而窗口显示的是它的**底部**（原点在左下），
        // SwiftUI 却从顶部开始排 → 屏幕上是一片空白。这个坑排查了很久。
        hosting.view.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: height)
        hosting.view.layoutSubtreeIfNeeded()
    }

    /// 先在宽松高度下量出内容的自然高度
    private func measureHeight() -> CGFloat {
        hosting.view.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: 4000)
        hosting.view.layoutSubtreeIfNeeded()
        let measured = max(hosting.preferredContentSize.height,
                           hosting.view.fittingSize.height)
        // 量不出来时的兜底：宁可高一点，也别显示成一条缝
        return measured > 80 ? measured : 320
    }

    /// 顶边贴住菜单栏底边，水平对齐状态项并夹在屏幕内
    private func positionPanel(anchor: NSWindow) {
        let size = panel.frame.size
        // 状态项窗口就是菜单栏那一条，它的 minY 即菜单栏底边
        let top = anchor.frame.minY
        let screenFrame = (anchor.screen ?? NSScreen.main)?.frame ?? anchor.frame

        var x = anchor.frame.midX - size.width / 2
        x = min(max(x, screenFrame.minX + 8), screenFrame.maxX - size.width - 8)

        panel.setFrame(NSRect(x: x.rounded(), y: (top - size.height).rounded(),
                              width: size.width, height: size.height),
                       display: true)
    }

    // MARK: - 点别处收起

    private func installGlobalMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            // AppKit 的事件回调就在主线程，直接认下来，省一次跨线程跳
            MainActor.assumeIsolated {
                guard let self else { return }
                // 全局监听拿不到"点的是谁"，只能自己比坐标：
                // 点在面板自己身上（开关、按钮）绝不能收起，否则点一下就没了。
                if self.panel.frame.contains(NSEvent.mouseLocation) { return }
                self.closePanelAutomatically()
            }
        }
    }

    private func removeGlobalMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }
}
