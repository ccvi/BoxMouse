import SwiftUI

// ============================================================
// 鼠标页：滚轮增强 + 附加按键
//
// 位置紧挨「手势」：这两块其实是同一件事的两种触发方式（手指 vs 滚轮/侧键），
// 用户找「鼠标能干什么」的时候不该跨页翻。
//
// 这一页的所有功能都挂在**独立的事件 tap** 上，和「手势引擎」总开关平级：
// 用户完全可能只想用平滑滚轮、一条手势都不想要。所以这里有自己的一级开关，
// 且只有真开了某一项才会去挂 tap（见 BoxMouseSettings.needsEventTap）。
// ============================================================

struct MouseTabView: View {
    @ObservedObject var model: AppModel

    private var settings: Binding<BoxMouseSettings> {
        Binding(get: { model.store.settings }, set: { model.store.settings = $0 })
    }

    private var enabled: Bool { model.store.settings.mouseControlEnabled }
    private var smoothing: Bool { model.store.settings.smoothScrollEnabled }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                masterCard
                wheelCard
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.5)
                sideButtonCard
                    .disabled(!enabled)
                    .opacity(enabled ? 1 : 0.5)
                noteCard
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 总开关

    private var masterCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("启用鼠标控制")
                            .font(.system(size: 13, weight: .medium))
                        Text("滚轮增强与侧键动作，和手势引擎互相独立：可以只开这一项、不用任何手势。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Toggle("", isOn: settings.mouseControlEnabled)
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
                        Button("去授权") { model.selectedTab = .permissions }
                            .buttonStyle(.borderless)
                            .font(.system(size: 11.5))
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        if !model.hasAccessibility { return .orange }
        if !enabled || !model.store.settings.mouseControlActive { return Theme.secondaryText }
        return model.engineRunning ? .green : .orange
    }

    private var statusText: String {
        if !model.hasAccessibility { return "未获得辅助功能授权，鼠标控制不会生效" }
        if !enabled { return "总开关已关闭，滚轮与侧键都按系统默认走" }
        if !model.store.settings.mouseControlActive { return "总开关已打开，但下面还没有启用任何一项" }
        return model.engineRunning ? "正在接管鼠标事件" : "引擎未运行，可到「通用」页看原因"
    }

    // MARK: - 滚轮

    private var wheelCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(text: "滚轮")

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("平滑滚动")
                            .font(.system(size: 12.5))
                        Text("把鼠标滚轮的「一格一格」摊成带缓动的连续滚动。触控板和妙控鼠标自带平滑，不受影响。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: settings.smoothScrollEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                HStack(spacing: 10) {
                    Text("滚动距离")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 56, alignment: .leading)
                    Text("短")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                    Slider(value: settings.smoothScrollStrength, in: 0.5...2.0, step: 0.1)
                        .controlSize(.small)
                    Text("长")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                    Text(String(format: "%.1f×", model.store.settings.smoothScrollStrength))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(smoothing ? Color.primary : Theme.secondaryText)
                        .frame(width: 38, alignment: .trailing)
                }
                .disabled(!smoothing)
                .opacity(smoothing ? 1 : 0.5)

                Divider().opacity(0.4)

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("滚轮反方向")
                            .font(.system(size: 12.5))
                        Text("上下和左右一起反转。触控板、妙控鼠标也一起生效。")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer(minLength: 12)
                    Toggle("", isOn: settings.invertScrollEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
    }

    // MARK: - 附加按键

    private var sideButtonCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(text: "附加按键")
                    Text("给侧键配一个动作，按下就执行；不配则保持原样（按住侧键画轨迹）。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }

                Divider().opacity(0.4)
                sideRow(title: "Forward Button",
                        subtitle: "靠近鼠标前端的那颗侧键（按钮 4）",
                        isOn: forwardEnabled,
                        action: forwardAction)
                Divider().opacity(0.4)
                sideRow(title: "Back Button",
                        subtitle: "靠近鼠标后端的那颗侧键（按钮 3）",
                        isOn: backEnabled,
                        action: backAction)
            }
        }
    }

    @ViewBuilder
    private func sideRow(title: String,
                         subtitle: String,
                         isOn: Binding<Bool>,
                         action: Binding<GestureAction>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            if isOn.wrappedValue {
                ActionEditorSection(action: action)
            }
        }
    }

    /// 侧键没设过动作时是 nil。「没设」和「设成了快捷键但没录键」是两回事，
    /// 所以这里用一个开关承载 nil，而不是拿空动作顶上。
    private var forwardEnabled: Binding<Bool> {
        Binding(
            get: { model.store.settings.forwardButtonAction != nil },
            set: { on in
                model.store.settings.forwardButtonAction = on
                    ? GestureAction(kind: .browser, browserOp: .forward)
                    : nil
            }
        )
    }

    private var backEnabled: Binding<Bool> {
        Binding(
            get: { model.store.settings.backButtonAction != nil },
            set: { on in
                model.store.settings.backButtonAction = on
                    ? GestureAction(kind: .browser, browserOp: .back)
                    : nil
            }
        )
    }

    private var forwardAction: Binding<GestureAction> {
        Binding(
            get: { model.store.settings.forwardButtonAction
                    ?? GestureAction(kind: .browser, browserOp: .forward) },
            set: { model.store.settings.forwardButtonAction = $0 }
        )
    }

    private var backAction: Binding<GestureAction> {
        Binding(
            get: { model.store.settings.backButtonAction
                    ?? GestureAction(kind: .browser, browserOp: .back) },
            set: { model.store.settings.backButtonAction = $0 }
        )
    }

    // MARK: - 说明

    private var noteCard: some View {
        Card(padding: 16) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                VStack(alignment: .leading, spacing: 6) {
                    Text("几点实际情况")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondaryText)
                    Text("· 平滑滚动只作用于鼠标的离散滚轮。触控板那种带惯性的连续滚动系统已经处理过，再来一遍会发飘。\n"
                         + "· 反方向是原地翻转事件里的位移，不重建事件，所以触控板的惯性不会被切断。\n"
                         + "· 侧键一旦配了动作，那颗键就不再能画轨迹；把它的开关关掉就恢复成按住画轨迹。")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(0.9)
    }
}
