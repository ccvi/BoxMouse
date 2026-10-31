// BoxMouse 图标渲染器
// 为什么用代码画：图标需要可版本化、任意尺寸锐利、几何可微调；
// 全在 1024×1024 设计坐标系（左上为原点，y 向下，跟 SVG 一致）里定义，
// 缩放到各尺寸时只做等比缩放，不会出现 AI 生成的怪点/断笔。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

let S: CGFloat = 1024

// MARK: - 基础工具

func hexColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255
    let g = CGFloat((hex >> 8) & 0xFF) / 255
    let b = CGFloat(hex & 0xFF) / 255
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 翻转成 y 向下的设计坐标系
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ ctx: CGContext, to path: String) {
    guard let img = ctx.makeImage() else { fatalError("makeImage failed") }
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("dest failed")
    }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - 图形路径

/// macOS 标准图标体：1024 画布里 824×824，圆角 185
func squircle() -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    return CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)
}

// 以下几何全部定义在「图形局部坐标系」600×600 里，
// 最后统一做 平移 → 旋转 → 缩放 落到画布中央，改构图只动一处。

/// 指针光标（经典带尾足的箭头），尖角在 (330, 40)
/// 外轮廓用白色描边 + 填充，让所有折角自带圆角
func pointerPath() -> CGPath {
    let pts: [CGPoint] = [
        CGPoint(x: 330, y: 40),     // 尖端
        CGPoint(x: 330, y: 271),    // 左边到底
        CGPoint(x: 373, y: 233),    // 内凹缺口
        CGPoint(x: 407, y: 314),    // 尾足左下
        CGPoint(x: 437, y: 301),    // 尾足右下
        CGPoint(x: 401, y: 222),    // 尾足内侧
        CGPoint(x: 476, y: 218),    // 箭身右下角
    ]
    let p = CGMutablePath()
    p.move(to: pts[0])
    for pt in pts.dropFirst() { p.addLine(to: pt) }
    p.closeSubpath()
    return p
}

/// 手势轨迹：从鼠标按下点（左下圆点）画出一条 S 形笔迹，收进指针体内
func trailPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 150, y: 520))
    p.addCurve(to: CGPoint(x: 334, y: 226),
               control1: CGPoint(x: 170, y: 432),
               control2: CGPoint(x: 318, y: 352))
    return p
}

/// 局部坐标 → 画布坐标（绕图形重心旋转，微倾斜更有动势）
func applyGlyphTransform(_ ctx: CGContext) {
    let glyphCenter = CGPoint(x: 290, y: 303)
    ctx.translateBy(x: 512, y: 505)
    ctx.rotate(by: -6 * .pi / 180)
    ctx.scaleBy(x: 1.22, y: 1.22)
    ctx.translateBy(x: -glyphCenter.x, y: -glyphCenter.y)
}

// MARK: - 绘制

func renderIcon() -> CGContext {
    let ctx = makeContext(1024, 1024)
    let body = squircle()

    // 1. 底色渐变（左上亮蓝 → 右下深靛蓝）
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                          colors: [hexColor(0x4FA6FF), hexColor(0x0A7BEF), hexColor(0x16307F)] as CFArray,
                          locations: [0.0, 0.52, 1.0])!
    ctx.drawLinearGradient(grad,
                           start: CGPoint(x: 120, y: 110),
                           end: CGPoint(x: 900, y: 930),
                           options: [])
    // 2. 顶部高光（营造玻璃质感，不做外投影）
    let gloss = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                           colors: [hexColor(0xFFFFFF, 0.22), hexColor(0xFFFFFF, 0.0)] as CFArray,
                           locations: [0.0, 1.0])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: 512, y: 100),
                           end: CGPoint(x: 512, y: 500),
                           options: [])
    ctx.restoreGState()

    // 3. 图形层：统一白色 + 轻投影（只在体内部，投影很淡）
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: 7),
                  blur: 15,
                  color: hexColor(0x00122E, 0.20))
    ctx.setFillColor(hexColor(0xFFFFFF))
    ctx.setStrokeColor(hexColor(0xFFFFFF))
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    ctx.saveGState()
    applyGlyphTransform(ctx)

    // 轨迹笔迹
    ctx.setLineWidth(46)
    ctx.addPath(trailPath())
    ctx.strokePath()

    // 起点圆点（按下位置）
    ctx.fillEllipse(in: CGRect(x: 150 - 44, y: 520 - 44, width: 88, height: 88))

    // 指针（先描边再填充，折角自然变圆）
    ctx.setLineWidth(14)
    ctx.addPath(pointerPath())
    ctx.strokePath()
    ctx.addPath(pointerPath())
    ctx.fillPath()

    ctx.restoreGState()
    ctx.restoreGState()
    return ctx
}

// MARK: - 输出

// 输出目录：允许命令行传入（打包脚本会在临时目录里生成，避免污染工作区）；
// 不传则落在工程根目录。
let root: String = {
    if CommandLine.arguments.count > 1, CommandLine.arguments[1].hasPrefix("/") {
        return CommandLine.arguments[1]
    }
    return "/Users/chen/WorkBuddy/CodeWork/BoxMouse"
}()
try? FileManager.default.createDirectory(atPath: root + "/assets",
                                         withIntermediateDirectories: true)
let master = renderIcon()
savePNG(master, to: "\(root)/assets/AppIcon-1024.png")

// 对比预览：亮色 / 暗色两种背景下的 256 / 128 / 64 / 32 尺寸
func renderPreview() -> CGContext {
    let W = 1120, H = 664
    let ctx = makeContext(W, H)
    let icon = master.makeImage()!

    func strip(y: CGFloat, bg: CGColor) {
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: y, width: CGFloat(W), height: 280))
    }
    strip(y: 20, bg: hexColor(0xF2F2F7))
    strip(y: 320, bg: hexColor(0x1C1C1E))
    ctx.setFillColor(hexColor(0xFFFFFF))
    ctx.fill(CGRect(x: 0, y: 600, width: CGFloat(W), height: 64))

    let sizes: [CGFloat] = [192, 128, 64, 32]
    for (row, y) in [54.0, 354.0].enumerated() {
        var x: CGFloat = 40
        for s in sizes {
            ctx.saveGState()
            // 在 y 向下坐标系里画图需要翻转图像本身
            ctx.translateBy(x: x, y: y + s)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(icon, in: CGRect(x: 0, y: 0, width: s, height: s))
            ctx.restoreGState()
            x += s + 40
        }
        _ = row
    }

    // 文字说明：ctx 已是 y 向下坐标系，用 flipped: true 的 NSGraphicsContext 直接落字
    let str = "BoxMouse · App Icon v1.0.0" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor
    ]
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    str.draw(at: NSPoint(x: 40, y: 620), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return ctx
}
savePNG(renderPreview(), to: "\(root)/assets/icon-preview.png")

print("icon rendered")
