import SwiftUI
import AppKit

// ============================================================
// 通用设置
// ============================================================

struct GeneralView: View {
    @ObservedObject var model: AppModel

    private var settings: Binding<BoxMouseSettings> {
        Binding(get: { model.store.settings }, set: { model.store.settings = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                engineCard
                targetCard
                trailCard
                feedbackCard
                appearanceCard
                multiTouchCard
                dataCard
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 引擎

    private var engineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用手势引擎")
                            .font(.system(size: 13, weight: .medium))
                        Text("关闭后所有鼠标手势都会停用，普通右键菜单不受影响。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Toggle("", isOn: settings.engineEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    if !model.hasAccessibility {
                        Button("去授权") {
                            model.selectedTab = .permissions
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11.5))
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        if !model.hasAccessibility { return .orange }
        return model.engineRunning ? .green : Theme.secondaryText
    }

    private var statusText: String {
        if !model.hasAccessibility { return "未获得辅助功能授权，手势不会触发" }
        return model.engineRunning ? "正在监听鼠标事件" : "引擎已停止"
    }

    // MARK: - 目标应用

    private var targetCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("作用域判定")
                    .font(.system(size: 13, weight: .medium))

                Picker("目标应用", selection: settings.targetMode) {
                    ForEach(TargetMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(model.store.settings.targetMode == .frontmost
                     ? "按键那一刻谁在最前面，就按谁的作用域匹配。最稳定，推荐。"
                     : "按指针下面压着的窗口所属应用匹配。适合多窗口并排、不想先切窗口的场景。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)

                Divider().opacity(0.4)

                Toggle(isOn: settings.lockWindow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("锁定精确窗口")
                            .font(.system(size: 12.5))
                        Text("关闭/最小化只作用于按键时那个窗口，而不是执行时的焦点窗口。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
    }

    // MARK: - 轨迹外观

    private var trailCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("绘制反馈")
                    .font(.system(size: 13, weight: .medium))

                Toggle(isOn: settings.showTrail) {
                    Text("手势过程中在屏幕上显示轨迹")
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                HStack(spacing: 16) {
                    HStack(spacing: 8) {
                        Text("颜色")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                        ColorPicker("", selection: Binding<Color>(
                            get: {
                                Color(nsColor: NSColor(hexString: model.store.settings.trailColorHex) ?? .systemRed)
                            },
                            set: { newColor in
                                // ColorPicker 给的是 SwiftUI.Color，先转 NSColor 才能取十六进制
                                model.store.settings.trailColorHex = NSColor(newColor).hexString
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }

                    HStack(spacing: 8) {
                        Text("粗细")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                        Slider(value: settings.trailWidth, in: 1...8, step: 0.5)
                            .frame(width: 120)
                        Text(String(format: "%.1f", model.store.settings.trailWidth))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                }
                .disabled(!model.store.settings.showTrail)

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("最短轨迹长度")
                            .font(.system(size: 12.5))
                        Text("低于这个长度的拖动会被当成一次普通点击。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Stepper(value: settings.minPathLength, in: 8...80, step: 2) {
                        Text("\(Int(model.store.settings.minPathLength)) pt")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
        }
    }

    // MARK: - 反馈

    /// 手势结束后在屏幕上给一句反馈。
    ///
    /// 静默启动之后没有主界面可看，"认出来没有"全靠这个提示。
    /// 两条说明必须写清楚：提示是在手势**结束后**才出的（不是边画边出），
    /// 以及关掉这两项也拦不住"动作执行失败"——那是另一类信息，不给关。
    private var feedbackCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("反馈")
                    .font(.system(size: 13, weight: .medium))

                Toggle(isOn: settings.showSuccessFeedback) {
                    Text("显示成功匹配提示")
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Toggle(isOn: settings.showUnrecognizedFeedback) {
                    Text("显示未识别手势提示")
                        .font(.system(size: 12.5))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("提示在手势结束后显示；即使关闭以上选项，动作执行失败仍会提示。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    // MARK: - 菜单栏与 Dock

    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("菜单栏与 Dock")
                    .font(.system(size: 13, weight: .medium))

                Toggle(isOn: settings.hideDockIcon) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("隐藏 Dock 图标")
                            .font(.system(size: 12.5))
                        Text("让 BoxMouse 只在菜单栏驻留。隐藏后主窗口从菜单栏浮窗的「打开主窗口」进入。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Image(systemName: "menubar.rectangle")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                    Text("菜单栏图标常驻，点一下就能开关引擎、看最近触发的手势。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
    }

    // MARK: - 多指触控（占位）

    private var multiTouchCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("多指触控手势")
                            .font(.system(size: 13, weight: .medium))
                        Text("三至五指轻触、四向滑动、捏合与旋转等 34 类触控手势。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Text("开发中")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                        .foregroundStyle(.orange)
                }

                Text("这一项需要直接读取触控板的多点触控设备（IOHID 层），1.x 版本先只做鼠标与修饰键手势，触控面板的录入与匹配引擎会在后续版本接入。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 数据

    private var dataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("配置")
                    .font(.system(size: 13, weight: .medium))

                HStack(spacing: 8) {
                    Button("备份配置…") { model.backupConfig() }
                    Button("恢复配置…") { model.restoreConfig() }
                    Spacer()
                    Button("打开配置文件夹") {
                        NSWorkspace.shared.open(model.store.configDirectory)
                    }
                }
                .font(.system(size: 12))

                Text("备份打包全部手势、作用域与设置，一个文件即可搬到别的机器；恢复会整体覆盖当前配置，覆盖前自动留一份快照。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
