import SwiftUI

// ============================================================
// 手势轨迹缩略图
//
// 归一化坐标落在 [-1,1]，等比缩放（不按宽高各自拉伸），
// 否则"一条横线"和"一条竖线"会被拉成同样大小，反而看不出区别。
// ============================================================

struct PathThumbnail: View {
    let path: [PathPoint]
    var lineWidth: CGFloat = 1.8
    var tint: Color = Color.primary
    var showsFrame: Bool = true
    var dotColor: Color = Color(red: 0.95, green: 0.23, blue: 0.19)
    /// 尺寸与留白可调：表格里是 80×38，菜单栏浮窗的「最近触发」是 38×22
    var size: CGSize = CGSize(width: 80, height: 38)
    var padding: CGFloat = 8

    var body: some View {
        Canvas { context, size in
            guard path.count > 1 else { return }
            // 按轴各自铺满：缩略图要的是"一眼看出一二"，不是精确比例。
            // 用短边等比会让"一条横线"只占中间一小截，反而看不出形状。
            let extentX = size.width / 2 - padding
            let extentY = size.height / 2 - padding
            guard extentX > 1, extentY > 1 else { return }

            // 显示前先做直线修正：等比归一化保真了真实手抖，
            // 按轴铺满会把横线上 ±5% 的抖动放大成肉眼可见的锯齿
            let display = PathRecognizer.displayStraighten(path)
            let points = display.map { point in
                CGPoint(x: size.width / 2 + point.x * extentX,
                        y: size.height / 2 + point.y * extentY)
            }

            var line = Path()
            line.move(to: points[0])
            for point in points.dropFirst() {
                line.addLine(to: point)
            }
            context.stroke(line,
                           with: .color(tint.opacity(0.85)),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            // 起点红点：告诉用户"从哪儿开始画"
            let dotRadius: CGFloat = 2.4
            let start = points[0]
            context.fill(Path(ellipseIn: CGRect(x: start.x - dotRadius,
                                                y: start.y - dotRadius,
                                                width: dotRadius * 2,
                                                height: dotRadius * 2)),
                         with: .color(dotColor))
        }
        .frame(width: size.width, height: size.height)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(showsFrame ? 1 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Theme.hairline, lineWidth: showsFrame ? 1 : 0)
        )
    }
}

/// 表格行首的启用勾选框
struct RowCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                .fill(isOn ? Theme.accent : Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                        .stroke(isOn ? Color.clear : Theme.hairline, lineWidth: 1.2)
                )
                .overlay(
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(isOn ? 1 : 0)
                )
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }
}
