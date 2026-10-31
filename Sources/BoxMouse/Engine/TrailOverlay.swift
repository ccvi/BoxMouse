import AppKit

// ============================================================
// 绘制轨迹的屏幕浮层
//
// 为什么要有：手势是「盲画」——没有视觉反馈时用户不知道自己画成了什么形状，
// 匹配失败会以为是应用没反应。浮层只在绘制期间存在，画完立刻消失。
//
// 🔴 窗口尺寸是这块代码的核心约束，不是随手定的。实测（`--memprobe-shot`，
// 60 帧增量重绘，每个尺寸一个独立进程）：
//
//     400×300 → +4.5 MB      640×480 → +5.5 MB
//     800×600 → +61.6 MB    1024×768 → +76.5 MB    1710×1107 → +86.3 MB
//
// 640×480 到 800×600 之间是一道断崖：面积只差 1.56 倍，内存差 11 倍。
// 系统在约 1.9M 像素以上换成全量 IOSurface 缓冲，而这块 surface 分配出去
// 就不还给 client（静置基线 41 → 64 MB，画完不回落）。所以：
//   · 从 640×480 起步，绝大多数手势画幅只有 200-400pt，够用；
//   · 只有真的画出去才扩窗，扩多少算多少，绝不预先铺满整屏；
//   · 窗口实例复用，不再一次手势造一个（旧实现每次 show 都新建全屏窗口，
//     九成面积是空的，纯烧内存）。
//
// 层级 .statusBar：高于普通窗口但低于系统弹窗，且不进 Mission Control 的窗口列表。
// ============================================================

@MainActor
final class TrailOverlay {

    private var window: NSWindow?
    private var view: TrailView?
    /// 本次绘制落在哪块屏上（append 只有屏幕坐标，靠它换算成窗口局部坐标）
    private var host: NSScreen?

    /// 起始尺寸。见文件头的测量表：这个尺寸以内，系统走稀疏合并路径。
    private static let initialSize = CGSize(width: 640, height: 480)
    /// 扩窗步进。一次扩到位、尺寸向上取整到 256：
    /// 每扩一次都要让系统重分配一层 surface，两次之间还会各留一份在内存里，
    /// 所以宁可一次多扩一点，也别一帧一帧地挤（实测 64 步进画满屏要扩 11 次，
    /// 峰值比 256 步进高出十来兆）。
    private static let growStep: CGFloat = 256
    /// 轨迹离边缘不到这个距离就扩窗，别等被裁掉才反应
    private static let edgePadding: CGFloat = 24

    // MARK: - 对外

    func show(at point: CGPoint, color: NSColor, width: CGFloat) {
        guard let screen = screen(containing: point) else { return }
        host = screen

        let area = screen.frame.size
        let local = localPoint(point, screen)

        let start = CGSize(width: min(Self.initialSize.width, area.width),
                           height: min(Self.initialSize.height, area.height))
        // 以起点为中心开窗，钳在屏幕内（贴边画时窗口不越界）
        let origin = clamp(CGPoint(x: local.x - start.width / 2,
                                   y: local.y - start.height / 2),
                           size: start, area: area)

        let (panel, trail) = ensureWindow()
        trail.color = color
        trail.lineWidth = width
        panel.alphaValue = 1

        place(panel: panel, trail: trail, origin: origin, size: start, screen: screen)
        trail.setScreenOrigin(origin)
        trail.reset(at: local)
        panel.orderFrontRegardless()
    }

    func append(_ point: CGPoint) {
        guard let screen = host, let panel = window, let trail = view else { return }
        let local = localPoint(point, screen)
        trail.append(local: local)
        growIfNeeded(local: local, screen: screen, panel: panel, trail: trail)
    }

    func hide() {
        window?.orderOut(nil)
        view?.clear()
        // 窗口与视图留着复用：反复创建/销毁会把 surface 反复分配，
        // 而系统收不回去，常驻只涨不跌。
    }

    // MARK: - 窗口

    private func ensureWindow() -> (NSWindow, TrailView) {
        if let window, let view { return (window, view) }

        let panel = NSWindow(contentRect: NSRect(origin: .zero, size: Self.initialSize),
                             styleMask: .borderless,
                             backing: .buffered,
                             defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary,
                                    .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let trail = TrailView(frame: NSRect(origin: .zero, size: Self.initialSize))
        panel.contentView = trail

        window = panel
        view = trail
        return (panel, trail)
    }

    /// 把窗口摆到「屏幕局部 y 向下」坐标系里的 origin / size 上。
    /// AppKit 的窗口 frame 是 y 向上的，这里做一次翻转。
    private func place(panel: NSWindow, trail: TrailView,
                       origin: CGPoint, size: CGSize, screen: NSScreen) {
        let frame = NSRect(x: screen.frame.minX + origin.x,
                           y: screen.frame.minY + (screen.frame.height - origin.y - size.height),
                           width: size.width,
                           height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
        if trail.frame.size != size {
            trail.frame = NSRect(origin: .zero, size: size)
        }
    }

    /// 轨迹画出安全区就扩窗。只扩不缩、一次扩到位：
    /// 改尺寸会触发 surface 重分配，扩得碎比扩得大更费。
    private func growIfNeeded(local: CGPoint, screen: NSScreen,
                              panel: NSWindow, trail: TrailView) {
        let size = trail.frame.size
        let origin = trail.screenOrigin
        let safe = CGRect(x: origin.x + Self.edgePadding,
                          y: origin.y + Self.edgePadding,
                          width: max(0, size.width - Self.edgePadding * 2),
                          height: max(0, size.height - Self.edgePadding * 2))
        guard !safe.contains(local) else { return }

        let area = screen.frame.size
        // 包围盒含起点与全部已画点，加上边距就是"至少要多大"
        let content = trail.contentBounds
            .offsetBy(dx: origin.x, dy: origin.y)
            .union(CGRect(x: local.x, y: local.y, width: 1, height: 1))

        func stepped(_ value: CGFloat) -> CGFloat {
            ceil(max(value, Self.growStep) / Self.growStep) * Self.growStep
        }
        // 只扩不缩：已经付过账的尺寸缩回去，下次还要再付一遍
        let width = min(max(stepped(content.width + Self.edgePadding * 2), size.width), area.width)
        let height = min(max(stepped(content.height + Self.edgePadding * 2), size.height), area.height)
        let newSize = CGSize(width: width, height: height)

        // 屏幕已经装不下了（画满屏）：不扩，多出来的点照画，只是被窗口裁掉
        guard newSize.width > size.width + 0.5 || newSize.height > size.height + 0.5 else {
            return
        }

        let newOrigin = clamp(CGPoint(x: content.midX - width / 2,
                                      y: content.midY - height / 2),
                               size: newSize, area: area)
        trail.shift(to: newOrigin)
        place(panel: panel, trail: trail, origin: newOrigin, size: newSize, screen: screen)
        // 坐标系变了，全部重绘一次（扩窗本来就不频繁）
        trail.needsDisplay = true
    }

    // MARK: - 坐标

    /// 事件坐标（y 向下，主屏顶边为 0）→ AppKit 全局坐标（y 向上，主屏底边为 0）
    private func appKitPoint(_ point: CGPoint) -> CGPoint {
        let primaryTop = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return CGPoint(x: point.x, y: primaryTop - point.y)
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        let probe = appKitPoint(point)
        return NSScreen.screens.first { $0.frame.contains(probe) } ?? NSScreen.main
    }

    /// 事件坐标 → 屏幕局部坐标（y 向下，原点在屏幕左上），窗口几何全用这一套
    private func localPoint(_ point: CGPoint, _ screen: NSScreen) -> CGPoint {
        let global = appKitPoint(point)
        return CGPoint(x: global.x - screen.frame.minX,
                       y: screen.frame.maxY - global.y)
    }

    private func clamp(_ origin: CGPoint, size: CGSize, area: CGSize) -> CGPoint {
        CGPoint(x: min(max(origin.x, 0), max(0, area.width - size.width)),
                y: min(max(origin.y, 0), max(0, area.height - size.height)))
    }

}

// MARK: - 视图

private final class TrailView: NSView {

    /// 窗口左上角在屏幕局部坐标（y 向下）里的位置。点都存成视图坐标，
    /// 窗口一移动就得整体平移——扩窗时会调 shift。
    private(set) var screenOrigin: CGPoint = .zero

    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3

    private var points: [CGPoint] = []

    override var isFlipped: Bool { true }

    var contentBounds: CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func setScreenOrigin(_ origin: CGPoint) {
        screenOrigin = origin
    }

    func reset(at local: CGPoint) {
        points = [viewPoint(local)]
        needsDisplay = true
    }

    func clear() {
        points.removeAll()
    }

    func append(local: CGPoint) {
        let point = viewPoint(local)
        guard let previous = points.last else {
            points = [point]
            setNeedsDisplay(dotRect(around: point))
            return
        }
        // 太密的点没意义，还会让重绘变频繁
        if hypot(point.x - previous.x, point.y - previous.y) < 2 { return }
        points.append(point)
        // 🔴 只重绘新增线段附近的区域，千万别 needsDisplay = true。
        // 大窗口整屏 invalidate 会让系统把整块图层重新光栅化，手指稍快就卡。
        setNeedsDisplay(segmentRect(from: previous, to: point))
    }

    /// 窗口移动/改尺寸后，把所有点平移到新的视图坐标系里。
    /// 🔴 方向别搞反：窗口左边界右移（dx>0），同一点在视图里的 x 必须**变小**。
    /// 写成 += 会让坐标随每次扩窗累积漂移，包围盒越算越大，窗口一路扩到整屏。
    func shift(to newOrigin: CGPoint) {
        let dx = newOrigin.x - screenOrigin.x
        let dy = newOrigin.y - screenOrigin.y
        guard dx != 0 || dy != 0 else { return }
        points = points.map { CGPoint(x: $0.x - dx, y: $0.y - dy) }
        screenOrigin = newOrigin
    }

    private func viewPoint(_ local: CGPoint) -> CGPoint {
        CGPoint(x: local.x - screenOrigin.x, y: local.y - screenOrigin.y)
    }

    private func segmentRect(from a: CGPoint, to b: CGPoint) -> NSRect {
        let pad = lineWidth * 2   // 圆头线帽 + 起点标记都在这个外扩范围内
        return NSRect(x: min(a.x, b.x) - pad,
                      y: min(a.y, b.y) - pad,
                      width: abs(b.x - a.x) + pad * 2,
                      height: abs(b.y - a.y) + pad * 2)
    }

    private func dotRect(around point: CGPoint) -> NSRect {
        let radius = lineWidth * 2
        return NSRect(x: point.x - radius, y: point.y - radius,
                      width: radius * 2, height: radius * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else {
            // 单点阶段（极短一瞬）：小圆点就够，别画大色块
            if let first = points.first {
                let radius = lineWidth * 0.9
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: first.x - radius, y: first.y - radius,
                                            width: radius * 2, height: radius * 2)).fill()
            }
            return
        }
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        color.withAlphaComponent(0.92).setStroke()
        path.stroke()

        // 起点标记：小一点，只用来指示"从哪头开始"
        let first = points[0]
        let radius = lineWidth * 1.0
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: first.x - radius, y: first.y - radius,
                                    width: radius * 2, height: radius * 2)).fill()
    }
}
