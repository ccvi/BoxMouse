import SwiftUI
import AppKit

// ============================================================
// 轨迹录入控件
//
// 用 NSView 而不是 SwiftUI 手势：这里要的是"按下→拖动→松开"的原始点序列，
// SwiftUI 的 DragGesture 会做最小位移阈值和坐标系转换，反而丢细节。
//
// 采集到的是**视图坐标**，出去之前统一归一化——存屏幕坐标的话，
// 换个分辨率或换台机器模板就全废了。
// ============================================================

struct PathCaptureView: NSViewRepresentable {
    /// 归一化模板（外部传入用于展示既有手势）
    var template: [PathPoint]
    /// 描完一条新轨迹时回调（已归一化）
    var onCapture: ([CGPoint]) -> Void

    func makeNSView(context: Context) -> PathCaptureNSView {
        let view = PathCaptureNSView()
        view.onCapture = onCapture
        view.template = template
        return view
    }

    func updateNSView(_ nsView: PathCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        // 外部清空时同步清掉画布上的实时笔迹
        if template.isEmpty && !nsView.isDrawing {
            nsView.template = []
            nsView.clearLive()
        } else {
            nsView.template = template
        }
    }
}

final class PathCaptureNSView: NSView {

    var onCapture: (([CGPoint]) -> Void)?
    var template: [PathPoint] = [] {
        didSet { needsDisplay = true }
    }
    private(set) var isDrawing = false
    private var live: [CGPoint] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()

        NSColor.separatorColor.withAlphaComponent(0.7).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        border.lineWidth = 1
        border.stroke()

        let points = isDrawing ? live : mappedTemplate()
        guard points.count > 1 else {
            drawHintIfNeeded()
            return
        }

        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.line(to: point)
        }
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        // 起点
        let first = points[0]
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: CGRect(x: first.x - 3.5, y: first.y - 3.5, width: 7, height: 7)).fill()
    }

    private func drawHintIfNeeded() {
        let text = "按住鼠标在这里画一条轨迹" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2),
                  withAttributes: attributes)
    }

    /// 模板坐标 [-1,1] → 视图坐标
    ///
    /// 按轴各自铺满（跟列表缩略图一致）：这个框是宽扁的，
    /// 用短边等比会把一条竖线压成一小段，用户会以为手势"丢了一半"。
    private func mappedTemplate() -> [CGPoint] {
        guard template.count > 1 else { return [] }
        let extentX = bounds.width / 2 - 24
        let extentY = bounds.height / 2 - 18
        guard extentX > 4, extentY > 4 else { return [] }
        // 与缩略图一致：显示前压掉直线短轴上的手抖锯齿（只影响显示）
        let display = PathRecognizer.displayStraighten(template)
        return display.map {
            CGPoint(x: bounds.midX + CGFloat($0.x) * extentX,
                    y: bounds.midY + CGFloat($0.y) * extentY)
        }
    }

    func clearLive() {
        live = []
        needsDisplay = true
    }

    // MARK: - 采集

    override func mouseDown(with event: NSEvent) {
        isDrawing = true
        live = [convert(event.locationInWindow, from: nil)]
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDrawing else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let last = live.last, hypot(point.x - last.x, point.y - last.y) < 1.5 { return }
        live.append(point)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard isDrawing else { return }
        isDrawing = false
        defer { needsDisplay = true }

        // 太短的轨迹不算数：多半是误触，存下来会污染手势库
        guard live.count >= 4, PathRecognizer.length(live) > 12 else {
            live = []
            return
        }
        onCapture?(live)
        live = []
    }
}
