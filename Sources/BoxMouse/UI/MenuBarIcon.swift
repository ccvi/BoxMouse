import AppKit

// ============================================================
// 菜单栏图标
//
// 代码绘制（家族约定），并且必须是 template image：
// template 让系统按菜单栏明暗自动上色，深色模式下不会出现"白底黑图"。
//
// 字形：一条路线串起四个节点（照着用户给的参考图量出来的几何）——
// 从底部节点起笔，斜向左上，横穿到右侧，再斜上到顶部节点。
// 空心圆环 + 圆头连线，一笔都不多余；节点间距和环径来自原图实测，
// 不是随手摆的。
//
// 变体用 --dump-menubar-variants 导出对比图挑选，交付版本由 defaultVariant 决定。
// ============================================================

/// 字形变体。改动前先导出对比图看，别凭想象调。
enum MenuBarGlyphVariant: Int, CaseIterable {
    /// 环壁最厚：18pt 下最"实"，但内孔被挤小，离开参考图的通透感
    case ringsHeavy = 0
    /// 折中：介于参考图线宽与系统图标笔画之间
    case rings = 1
    /// 严格照参考图线宽比例（线宽 : 外径 = 0.2）
    case ringsLight = 2
    /// 实心圆点 + 连线：18pt 下辨识度最高
    case dots = 3

    var title: String {
        switch self {
        case .ringsHeavy: return "四环 · 厚壁"
        case .rings:      return "四环 · 折中"
        case .ringsLight: return "四环 · 忠于原图"
        case .dots:       return "四点 · 实心"
        }
    }
}

enum MenuBarIcon {

    /// 交付使用的字形
    static let defaultVariant: MenuBarGlyphVariant = .rings

    /// 返回 18×18 的 template 图（内部按 2 倍像素绘制，Retina 才不糊）
    static func make(pointSize: CGFloat = 18,
                     variant: MenuBarGlyphVariant = MenuBarIcon.defaultVariant) -> NSImage {
        let scale: CGFloat = 2
        let pixelSize = Int(pointSize * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelSize,
                                         pixelsHigh: pixelSize,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        rep.size = NSSize(width: pointSize, height: pointSize)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawGlyph(in: CGRect(x: 0, y: 0, width: pointSize, height: pointSize), variant: variant)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: NSSize(width: pointSize, height: pointSize))
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }

    // MARK: - 绘制

    /// 在 18×18 的逻辑坐标里画（设计稿 y 向下）
    static func drawGlyph(in rect: CGRect,
                          variant: MenuBarGlyphVariant = MenuBarIcon.defaultVariant,
                          tint: NSColor = .black) {
        let unit = rect.width / 18
        guard let context = NSGraphicsContext.current else { return }

        context.cgContext.saveGState()
        context.cgContext.translateBy(x: 0, y: rect.height)
        context.cgContext.scaleBy(x: 1, y: -1)
        // 之后所有坐标都按 18 的设计单位给，线宽也跟着缩放
        context.cgContext.scaleBy(x: unit, y: unit)

        for mark in marks(for: variant) {
            if mark.filled {
                tint.setFill()
                mark.path.fill()
            } else {
                tint.setStroke()
                mark.path.lineWidth = mark.width
                mark.path.lineCapStyle = .round
                mark.path.lineJoinStyle = .round
                mark.path.stroke()
            }
        }

        context.cgContext.restoreGState()
    }

    private struct Mark {
        var path: NSBezierPath
        var width: CGFloat
        var filled: Bool = false
    }

    // MARK: 几何（18 设计单位，y 向下）

    // 参考图实测（106×88，ink bbox 66×66）：
    //   环外径 20、线宽 4（环线宽 : 外径 = 1:5）
    //   节点中心 top(52.5,18.5) left(30,41.5) right(74.5,41.5) bottom(52.5,64.5)
    // 下面按「内容占 15 单位、四周各留 1.5」等比换算，节点间距与参考图一致。
    private static let topNode = CGPoint(x: 8.89, y: 3.66)
    private static let leftNode = CGPoint(x: 3.77, y: 8.89)
    private static let rightNode = CGPoint(x: 13.89, y: 8.89)
    private static let bottomNode = CGPoint(x: 8.89, y: 14.11)

    /// 环的外沿半径。四个变体统一保持这个外径，这样换线宽时整体大小不跳。
    private static let ringOuter: CGFloat = 2.35

    /// 由线宽反推环的中心线半径——外沿固定，线越粗中心线越往里收。
    private static func radius(forStroke stroke: CGFloat) -> CGFloat {
        ringOuter - stroke / 2
    }

    private static func marks(for variant: MenuBarGlyphVariant) -> [Mark] {
        let allNodes = [topNode, leftNode, rightNode, bottomNode]
        let allLinks: [(CGPoint, CGPoint)] = [(topNode, rightNode),
                                              (leftNode, rightNode),
                                              (leftNode, bottomNode)]
        switch variant {
        case .ringsHeavy:
            let stroke: CGFloat = 1.35
            return nodes(ringsAt: allNodes, links: allLinks,
                         stroke: stroke, radius: radius(forStroke: stroke), hollow: true)
        case .rings:
            let stroke: CGFloat = 1.05
            return nodes(ringsAt: allNodes, links: allLinks,
                         stroke: stroke, radius: radius(forStroke: stroke), hollow: true)
        case .ringsLight:
            let stroke: CGFloat = 0.92
            return nodes(ringsAt: allNodes, links: allLinks,
                         stroke: stroke, radius: radius(forStroke: stroke), hollow: true)
        case .dots:
            // 实心点直径要够大才像"节点"，否则只像线端点加了个粗头
            return nodes(ringsAt: allNodes, links: allLinks,
                         stroke: 1.05, radius: 1.85, hollow: false)
        }
    }

    /// 组装：连线 + 节点。
    /// 连线两端各让出一个环半径，否则线会从环的空心里穿过去——在 18pt 下看着像糊了。
    private static func nodes(ringsAt centers: [CGPoint],
                              links: [(CGPoint, CGPoint)],
                              stroke: CGFloat,
                              radius: CGFloat,
                              hollow: Bool) -> [Mark] {
        var result: [Mark] = []

        for (from, to) in links {
            let dx = to.x - from.x
            let dy = to.y - from.y
            let length = max(sqrt(dx * dx + dy * dy), 0.001)
            let ux = dx / length
            let uy = dy / length
            // 线端是圆头，墨迹会再外扩 stroke/2；收到「环外沿 - stroke/2」
            // 正好等于环的中心线半径，接线处才严丝合缝。
            let inset = hollow ? radius : radius * 0.8
            guard length > inset * 2 else { continue }

            let path = NSBezierPath()
            path.move(to: CGPoint(x: from.x + ux * inset, y: from.y + uy * inset))
            path.line(to: CGPoint(x: to.x - ux * inset, y: to.y - uy * inset))
            result.append(Mark(path: path, width: stroke))
        }

        for center in centers {
            let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius,
                                                   y: center.y - radius,
                                                   width: radius * 2,
                                                   height: radius * 2))
            result.append(Mark(path: path, width: hollow ? stroke : 0, filled: !hollow))
        }

        return result
    }

    // MARK: - 诊断

    /// 诊断用：把图标放大若干倍写成 PNG，方便肉眼检查字形
    static func dumpPreview(to path: String,
                            scale: CGFloat = 12,
                            variant: MenuBarGlyphVariant = MenuBarIcon.defaultVariant,
                            background: NSColor? = nil,
                            tint: NSColor = .black) {
        let pointSize: CGFloat = 18
        let pixelSize = Int(pointSize * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelSize,
                                         pixelsHigh: pixelSize,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // 默认留透明：白底会把"描边有多重"看错，叠到菜单栏底色上才是真实观感
        if let background {
            background.setFill()
            NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
        }
        drawGlyph(in: CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                  variant: variant,
                  tint: tint)
        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 诊断用：拼一条假的菜单栏（蓝色底 + 白色字形 + 两个系统符号），
    /// 用来判断"放进真菜单栏里粗细是否跟系统图标协调"。
    static func dumpStrip(to path: String, variant: MenuBarGlyphVariant, scale: CGFloat = 3) {
        let barHeight: CGFloat = 24
        let width: CGFloat = 150
        let pixelW = Int(width * scale)
        let pixelH = Int(barHeight * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelW,
                                         pixelsHigh: pixelH,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor(calibratedRed: 0.13, green: 0.42, blue: 0.78, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: barHeight).fill()

        // 我们自己的字形（菜单栏里实际就是 18×18 的 template 图）
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: 8, y: 3)
        drawGlyph(in: CGRect(x: 0, y: 0, width: 18, height: 18), variant: variant, tint: .white)
        context.cgContext.restoreGState()

        // 两个系统符号做参照：粗细/高度都对得上，才算"像原生"
        var x: CGFloat = 32
        for symbol in ["rectangle.on.rectangle", "bell.fill"] {
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                let configured = image.withSymbolConfiguration(
                    NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? image
                let size = configured.size
                let tinted = NSImage(size: size, flipped: false) { rect in
                    configured.draw(in: rect)
                    NSColor.white.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: x, y: (barHeight - size.height) / 2,
                                       width: size.width, height: size.height))
                x += size.width + 9
            }
        }

        NSGraphicsContext.restoreGraphicsState()

        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 自检用：字形实际墨迹覆盖率（0~1）。
    /// 全透明 = 菜单栏上等于没图标；接近 1 = 画成了一块实心方块，
    /// 两种都是"看不出来画了什么"，但肉眼在 18pt 下不容易察觉。
    static func inkCoverage(pointSize: CGFloat = 18,
                            variant: MenuBarGlyphVariant = MenuBarIcon.defaultVariant) -> Double {
        let pixelSize = Int(pointSize * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelSize,
                                         pixelsHigh: pixelSize,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        drawGlyph(in: CGRect(x: 0, y: 0, width: CGFloat(pixelSize), height: CGFloat(pixelSize)),
                  variant: variant)
        NSGraphicsContext.restoreGraphicsState()

        var inked = 0
        for y in 0..<pixelSize {
            for x in 0..<pixelSize {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.4 { inked += 1 }
            }
        }
        return Double(inked) / Double(pixelSize * pixelSize)
    }
}
