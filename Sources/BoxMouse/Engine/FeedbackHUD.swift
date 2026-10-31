import AppKit

/// 手势结束后的屏幕提示（小胶囊，固定在屏幕底部居中）。
///
/// 静默启动之后，这是唯一能看见「认出来没有」的地方——主界面不开也照样提示，
/// 所以它必须自己管窗口，不能借用 AppModel 的 toast（那个画在窗口里）。
///
/// 用 AppKit 直画而不是 SwiftUI：这类浮层一秒就消失，没必要为它准备一个
/// NSHostingView 的启动代价和内存。窗口也是懒创建——一次手势都没触发过，
/// 就不会有第二个窗口存在。
@MainActor
final class FeedbackHUD {

    enum Kind: Equatable {
        /// 匹配上了，带上手势名
        case success(String)
        /// 画了，但不像任何一条
        case unmatched
        /// 匹配上了，动作没执行成功
        case failure(String)
    }

    /// 这种提示该不该显示。
    ///
    /// 抽成纯函数供自检：用户关掉「成功提示」之后，**失败提示仍然必须出现**
    /// —— 那是"手势做了但没成"的唯一线索，不属于噪音。
    static func shouldShow(_ kind: Kind, showSuccess: Bool, showUnmatched: Bool) -> Bool {
        switch kind {
        case .success:   return showSuccess
        case .unmatched: return showUnmatched
        case .failure:   return true
        }
    }

    static let shared = FeedbackHUD()

    // MARK: - 配色（必须成对）

    /// 🔴 胶囊是**固定深色**，所以里面的字不能用 `.labelColor` / `.secondaryLabelColor`。
    ///
    /// 那两个是动态色，跟着系统外观翻转：浅色外观下解析成近黑色，
    /// 压在深色胶囊上等于看不见——真机就是这么报上来的（截图里"左半屏"三个字全黑）。
    /// 底色既然是写死的，前景也一律写死成与它配对的浅色。
    static let capsuleBackground = NSColor(white: 0.11, alpha: 0.88)
    /// 主文字：成功率最高的白（纯白在深底上会有点扎眼）
    static let capsuleTextColor = NSColor(white: 0.97, alpha: 1)
    /// 次要信息（"未识别手势"的图标）：比主文字暗一档，但仍然足够亮
    static let capsuleSecondaryTextColor = NSColor(white: 0.86, alpha: 1)

    /// 相对亮度（sRGB 加权）。给自检用来钉住"深底配浅字"。
    static func relativeBrightness(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else {
            return 0
        }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    /// 提示里最多显示多少个字：手势名可能很长，别让胶囊横到屏幕外
    private let maxTextWidth: CGFloat = 300
    /// 距屏幕可见区底边的高度。Dock 在底部时 visibleFrame 已经排除了它，
    /// 所以这就是「Dock 上沿再往上一点」。
    private let bottomInset: CGFloat = 20
    private let visibleDuration: TimeInterval = 1.1

    private init() {}

    // MARK: - 对外

    func show(_ kind: Kind) {
        let (symbol, text, tint) = content(for: kind)
        let container = Self.makeCapsule(symbol: symbol, text: text, tint: tint,
                                         maxTextWidth: maxTextWidth)

        let panel = ensurePanel()
        panel.contentView = container
        container.layoutSubtreeIfNeeded()
        let size = container.fittingSize
        panel.setContentSize(size)
        let screen = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        panel.setFrameOrigin(bottomCenterOrigin(on: screen, size: size))
        panel.alphaValue = 0
        // orderFrontRegardless：不激活应用、不抢焦点，但一定盖在最上面
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    // MARK: - 内容

    private func content(for kind: Kind) -> (symbol: String, text: String, tint: NSColor) {
        switch kind {
        case let .success(name):
            return ("checkmark.circle.fill", name, NSColor.systemGreen)
        case .unmatched:
            // 不写成"未识别手势"以外的抱怨，这里只交代事实
            return ("questionmark.circle.fill", "未识别手势", Self.capsuleSecondaryTextColor)
        case let .failure(name):
            return ("exclamationmark.triangle.fill", "\(name) · 执行失败", NSColor.systemOrange)
        }
    }

    private static func makeCapsule(symbol: String,
                                    text: String,
                                    tint: NSColor,
                                    maxTextWidth: CGFloat) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        // 固定色，不是 .labelColor——理由见 capsuleTextColor 上的注释
        label.textColor = Self.capsuleTextColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        // 长手势名横向截断，不换行：胶囊高度必须稳定，否则每帧都要重排
        label.preferredMaxLayoutWidth = maxTextWidth

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 11, bottom: 7, right: 12)

        stack.wantsLayer = true
        stack.layer?.backgroundColor = Self.capsuleBackground.cgColor
        stack.layer?.cornerRadius = 10
        stack.layer?.cornerCurve = .continuous
        return stack
    }

    // MARK: - 窗口

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // .floating：普通窗口之上、菜单栏之下；statusBar 会盖住菜单栏
        panel.level = .floating
        // 纯提示，不能吃掉任何点击
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // 全屏应用、其他 Space 上也要能看见
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        self.panel = panel
        return panel
    }

    /// 屏幕底部居中，压在 Dock 上方一点。
    ///
    /// 不用鼠标位置：手势结束时指针落在哪儿都有可能，提示跟着指针跑会到处跳，
    /// 视线得追着找。固定在底部中央，位置每次都一样，扫一眼就够。
    ///
    /// `visibleFrame` 已经把 Dock 和菜单栏排除掉了：Dock 在底部时它的 `minY` 就是
    /// Dock 上沿，所以「+ 一点间距」天然就是"Dock 上面"；Dock 在左右两侧或自动隐藏时
    /// 也不会被压住。用鼠标所在的那块屏，副屏操作时提示不会跑到主屏去。
    private func bottomCenterOrigin(on screen: NSScreen?, size: NSSize) -> NSPoint {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = visible.midX - size.width / 2
        // 屏幕窄 / 手势名特别长时，别让胶囊被挤出可见区
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        return NSPoint(x: x, y: visible.minY + bottomInset)
    }

    // MARK: - 自动消失

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleDuration, execute: work)
    }
}
