import SwiftUI
import AppKit

// ============================================================
// 视觉规范
//
// 参照图是一套标准 macOS 原生外观：系统蓝强调色、圆角卡片、
// 行间隔色、克制的分割线。这里集中定义，避免各视图各写一套色值。
// ============================================================

enum Theme {
    static let accent = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let accentSoft = Color(red: 0.0, green: 0.48, blue: 1.0).opacity(0.12)

    static let sidebarWidth: CGFloat = 220
    static let rowHeight: CGFloat = 52
    static let rowCorner: CGFloat = 8

    static let columnEnabled: CGFloat = 46
    static let columnPath: CGFloat = 96
    static let columnName: CGFloat = 180
    static let columnTrigger: CGFloat = 108
    static let columnScope: CGFloat = 88

    static var windowBackground: Color { Color(nsColor: .windowBackgroundColor) }
    static var contentBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var subtleFill: Color { Color(nsColor: .quaternaryLabelColor).opacity(0.06) }
    static var hairline: Color { Color(nsColor: .separatorColor).opacity(0.6) }
    static var secondaryText: Color { Color(nsColor: .secondaryLabelColor) }
}

/// 卡片容器
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.contentBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            )
    }
}

/// 小标题（卡片内的分区名）
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .textCase(.uppercase)
            .tracking(0.4)
    }
}

/// 分段选择器（参考图里"全部 / 已启用 / 已禁用"那一排）
struct PillSegmented<T: Hashable>: View {
    let options: [(value: T, title: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Theme.accent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
        )
    }
}

/// 底部工具条上的小按钮
struct ToolbarChip: View {
    let title: String
    var symbol: String? = nil
    var tint: Color = .primary
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(isEnabled ? tint : Theme.secondaryText.opacity(0.6))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(isEnabled ? 0.10 : 0.05))
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
