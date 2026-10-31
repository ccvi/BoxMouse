import SwiftUI
import AppKit

// ============================================================
// 关于
//
// 版面随窗口尺寸等比缩放：这个页面只有图标和几行字，固定字号在
// 大窗口里就是中间孤零零一小块、上下各一大片空白——看着像"调不了大小"。
// 用 GeometryReader 取可用尺寸算一个 0.72…1.5 的系数，图标和字号一起跟。
// ============================================================

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "10000"
    }

    /// 以 900×720 为基准（窗口默认尺寸），窗口越大内容越大，越小越紧凑
    private func scale(for size: CGSize) -> CGFloat {
        let byWidth = size.width / 900
        let byHeight = size.height / 720
        return min(max(min(byWidth, byHeight), 0.72), 1.5)
    }

    var body: some View {
        GeometryReader { geo in
            let s = scale(for: geo.size)

            VStack(spacing: 0) {
                Spacer(minLength: 24 * s)

                appIcon(scale: s)

                Text("BoxMouse")
                    .font(.system(size: 26 * s, weight: .semibold))
                    .padding(.top, 16 * s)

                Text("版本 \(version)（构建 \(build)）")
                    .font(.system(size: 11.5 * s))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4 * s)

                Text("本地运行的鼠标手势自动化工具")
                    .font(.system(size: 12.5 * s))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 10 * s)

                VStack(spacing: 8 * s) {
                    InfoRow(label: "作者", value: "ccvi1223", scale: s)
                    InfoRow(label: "邮箱", value: "ccvi1223@qq.com", scale: s, isLink: true)
                    InfoRow(label: "系统要求",
                            value: "macOS 15 及以上 · Apple 芯片（目标环境 macOS 26 / M5）",
                            scale: s)
                }
                .frame(maxWidth: 460 * s)
                .padding(.top, 26 * s)

                Text("所有手势配置保存在本机，不上传任何数据。")
                    .font(.system(size: 10.5 * s))
                    .foregroundStyle(Theme.secondaryText.opacity(0.8))
                    .padding(.top, 18 * s)

                Spacer(minLength: 24 * s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.windowBackground)
    }

    private func appIcon(scale s: CGFloat) -> some View {
        Group {
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
            } else {
                RoundedRectangle(cornerRadius: 26 * s, style: .continuous)
                    .fill(
                        LinearGradient(colors: [Color(red: 0.31, green: 0.65, blue: 1.0),
                                                Color(red: 0.09, green: 0.19, blue: 0.50)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        Image(systemName: "cursorarrow.motionlines")
                            .font(.system(size: 40 * s, weight: .light))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: 96 * s, height: 96 * s)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var scale: CGFloat = 1
    var isLink: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12 * scale) {
            Text(label)
                .font(.system(size: 11.5 * scale))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 64 * scale, alignment: .trailing)
            if isLink, let url = URL(string: "mailto:\(value)") {
                Link(value, destination: url)
                    .font(.system(size: 11.5 * scale))
            } else {
                Text(value)
                    .font(.system(size: 11.5 * scale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
