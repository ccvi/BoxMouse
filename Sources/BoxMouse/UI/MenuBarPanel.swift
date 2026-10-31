import SwiftUI
import AppKit

// ============================================================
// 菜单栏浮窗
//
// 定位：**看一眼 + 一两个开关**。不是把主窗口塞进弹窗——
// 手势库的搜索、筛选、批量操作只在主窗口做。
//
// 所以这里只放四块：在不在工作（总开关 + 状态）、有多少条手势、
// 三个系统开关（隐藏桌面图标 / 显示隐藏文件 / 锁定键盘）、
// 以及去主窗口的入口。
//
// 最后一块是隐藏 Dock 图标之后的"唯一出路"，不能漏。
// 「最近触发」列表已去掉：它在浮窗里占了将近一半高度，实际价值却很低
// （看过的都知道刚才画了什么），反而把真正要点的按钮挤下去了。
// ============================================================

struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    /// 三个系统开关的现场状态（真相在系统里，每次显示浮窗前重读）
    @ObservedObject var toggles: SystemTogglesModel
    /// 点"打开主窗口/设置/退出"时由控制器收起浮窗
    var onClose: () -> Void = {}

    private var settings: Binding<BoxMouseSettings> {
        Binding(get: { model.store.settings }, set: { model.store.settings = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            rule
            if !model.hasAccessibility {
                permissionRow
                rule
            }
            statsRow
            rule
            systemRows
            rule
            footer
        }
        .frame(width: 300)
        .background(Theme.windowBackground)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.accentSoft)
                Image(nsImage: MenuBarIcon.make(pointSize: 21))
                    .renderingMode(.template)
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("BoxMouse")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 5, height: 5)
                    Text(statusText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: settings.engineEnabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("手势引擎总开关")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statusColor: Color {
        if !model.hasAccessibility { return .orange }
        if !model.store.settings.engineEnabled { return Theme.secondaryText }
        return model.engineRunning ? .green : .orange
    }

    private var statusText: String {
        if !model.hasAccessibility { return "未授权辅助功能" }
        if !model.store.settings.engineEnabled { return "手势已暂停" }
        return model.engineRunning ? "正在监听鼠标手势" : "引擎未启动"
    }

    // MARK: - 未授权提示

    private var permissionRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text("还没有辅助功能权限")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Button("去授权") {
                onClose()
                model.openWindow?(.permissions)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - 概览

    private var statsRow: some View {
        HStack(spacing: 0) {
            stat(value: "\(model.totalGestureCount)", label: "手势")
            vRule
            stat(value: "\(model.enabledGestureCount)", label: "已启用")
            vRule
            stat(value: "\(model.appScopeCount)", label: "应用作用域")
        }
        .padding(.vertical, 11)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 三个系统开关
    //
    // 这三项管的是「系统长什么样」，跟手势库无关，所以只在这里给快捷入口，
    // 不占主窗口的设置页。真相在系统里（Finder 偏好 / 事件 tap 活着没有），
    // 每次显示浮窗前由控制器 refresh，切换后以实际结果回写。

    private var systemRows: some View {
        VStack(spacing: 0) {
            toggleRow(symbol: "display",
                      title: "隐藏桌面图标",
                      isOn: Binding(get: { toggles.hideDesktopIcons },
                                    set: { toggles.setDesktopIconsHidden($0) }))

            toggleRow(symbol: toggles.showHiddenFiles ? "eye" : "eye.slash",
                      title: "显示隐藏文件",
                      isOn: Binding(get: { toggles.showHiddenFiles },
                                    set: { toggles.setHiddenFilesShown($0) }))

            toggleRow(symbol: "keyboard",
                      title: "锁定键盘",
                      subtitle: toggles.keyboardAuthNeeded
                          ? "需要授权：系统设置 → 隐私与安全性 → 辅助功能"
                          : "清洁键盘时用 · 鼠标触控板不受影响",
                      subtitleIsWarning: toggles.keyboardAuthNeeded,
                      isOn: Binding(get: { toggles.keyboardLocked },
                                    set: { toggles.setKeyboardLocked($0) }))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func toggleRow(symbol: String,
                           title: String,
                           subtitle: String? = nil,
                           subtitleIsWarning: Bool = false,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(subtitleIsWarning ? Color.orange : Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onClose()
                model.openWindow?(nil)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .medium))
                    Text("打开主窗口")
                        .font(.system(size: 12))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Button {
                onClose()
                model.openWindow?(.general)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.bordered)
            .help("打开设置")

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.bordered)
            .help("退出 BoxMouse")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - 分割线

    private var rule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
    }

    private var vRule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 22)
    }
}
