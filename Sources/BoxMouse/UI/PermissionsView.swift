import SwiftUI
import AppKit

// ============================================================
// 权限
//
// 两项授权，各管一半功能：
//
// ① 辅助功能（Accessibility）：CGEventTap 靠它装上。没有它鼠标手势一条都不触发，
//    窗口操作（关/最小化/最大化）也做不了。
// ② 输入监控（Input Monitoring）：触摸板手势靠它。MultitouchSupport 读的是
//    IOHIDEventSystemClient，归这一项管，**辅助功能替代不了**。
//
// 这两项最容易混的地方：缺输入监控时，触摸板引擎会"启动成功"、设备也列得出来，
// 就是一个触点帧都收不到——从界面上完全看不出是权限问题。所以必须单列一张卡。
// ============================================================

struct PermissionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "accessibility")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(model.hasAccessibility ? Color.green : Color.orange)
                                .frame(width: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("辅助功能")
                                    .font(.system(size: 13, weight: .medium))
                                Text(model.hasAccessibility ? "已授权" : "未授权")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(model.hasAccessibility ? .green : .orange)
                            }
                            Spacer()
                            statusBadge
                        }

                        Divider().opacity(0.4)

                        Text("BoxMouse 需要这个权限来做两件事：读取鼠标按键与移动轨迹（判断你画了什么），以及把识别出的动作发回系统（快捷键、媒体键、关窗）。事件只在内存里流转，不写盘、不外发。")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            Button("打开系统设置") {
                                Permissions.openAccessibilitySettings()
                            }
                            Button("重新检测") {
                                model.refreshPermissions()
                                model.showToast(model.hasAccessibility ? "已授权" : "仍未授权")
                            }
                            Spacer()
                        }
                        .font(.system(size: 12))
                    }
                }

                if TrackpadEngine.isAvailable {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: "hand.tap")
                                    .font(.system(size: 22, weight: .light))
                                    .foregroundStyle(model.hasInputMonitoring ? Color.green : Color.orange)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("输入监控")
                                        .font(.system(size: 13, weight: .medium))
                                    Text(model.hasInputMonitoring ? "已授权" : "未授权")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(model.hasInputMonitoring ? .green : .orange)
                                }
                                Spacer()
                                badge(model.hasInputMonitoring)
                            }

                            Divider().opacity(0.4)

                            Text("触摸板手势要读触控板的原始触点（几根手指、往哪滑），这一项归「输入监控」管，辅助功能替代不了。没有它的时候触摸板引擎会照常启动、设备也能列出来，但一个触点帧都收不到——症状就是「触摸板手势没反应」。鼠标手势不受影响。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 8) {
                                Button("打开系统设置") {
                                    Permissions.openInputMonitoringSettings()
                                }
                                Button("请求授权") {
                                    Permissions.requestInputMonitoring()
                                }
                                Button("重新检测") {
                                    model.refreshPermissions()
                                    model.showToast(model.hasInputMonitoring ? "已授权" : "仍未授权")
                                }
                                Button("重启引擎") {
                                    model.restartTrackpadEngine()
                                }
                                Spacer()
                            }
                            .font(.system(size: 12))

                            Divider().opacity(0.4)

                            // 实时自检：把"引擎在跑但收不到帧"这件事从"看不见"变成"看得见"。
                            // 数字会一直跳，用户摸一下触控板就知道帧数有没有涨。
                            TrackpadLiveCheck(model: model)
                        }
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("授权后如果仍然不生效")
                            .font(.system(size: 12.5, weight: .medium))
                        BulletRow(text: "在「系统设置 → 隐私与安全性 → 辅助功能」里确认 BoxMouse 的开关是打开的。")
                        BulletRow(text: "触摸板手势还要「输入监控」那一项，在同一个面板的上一栏；两项都得开。")
                        BulletRow(text: "改过签名的版本可能被系统判为「不同的应用」，需要先移除旧条目再重新添加。")
                        BulletRow(text: "从别处拷来的 .app 第一次打开要先右键 →「打开」，否则会被隔离属性拦住。")
                        BulletRow(text: "授权后一般会立刻生效；若状态仍是「未授权」，点一下「重新检测」，还不行再重启应用。")
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
    }

    private func badge(_ ok: Bool) -> some View {
        Text(ok ? "正常" : "待处理")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill((ok ? Color.green : Color.orange).opacity(0.15)))
            .foregroundStyle(ok ? .green : .orange)
    }

    private var statusBadge: some View {
        Text(model.hasAccessibility ? "正常" : "待处理")
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill((model.hasAccessibility ? Color.green : Color.orange).opacity(0.15))
            )
            .foregroundStyle(model.hasAccessibility ? .green : .orange)
    }
}

private struct BulletRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.secondaryText)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 触摸板实时自检。
///
/// 「触摸板手势没反应」有两种完全不同的断法：
///   ① 一个触点帧都没收到（权限 / 设备没起来）
///   ② 帧收到了但没识别出手势（阈值不对）
/// 界面上两者长得一模一样，所以这里把引擎的实时计数直接摊出来：
/// 帧数一直 0 = 没收到；帧数在涨 = 收到了，问题在识别。
struct TrackpadLiveCheck: View {
    @ObservedObject var model: AppModel
    @State private var frames = 0
    @State private var fingers = 0
    @State private var waiting: TimeInterval = 0
    @State private var running = false
    @State private var modifiers: Set<ModifierKey> = []
    @State private var tick = 0

    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                Text("触摸板自检")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 18) {
                metric("收到帧数", "\(frames)")
                metric("当前手指数", frames > 0 ? "\(fingers)" : "—")
                metric("起手修饰键", modifiersText)
                metric("已运行", "\(Int(waiting)) 秒")
            }

            Text(hintText)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .onReceive(timer) { _ in
            let info = TrackpadEngine.diagnostics
            frames = info.frames
            fingers = info.fingers
            waiting = info.waiting
            running = info.running
            modifiers = info.modifiers
            tick += 1
        }
        // 诊断日志只在面板看得见的时候写盘：关掉面板就停，
        // 日常使用里不该每秒往磁盘写 10KB
        .onAppear { TrackpadEngine.setLogging(true) }
        .onDisappear { TrackpadEngine.setLogging(false) }
    }

    /// 起手那一刻读到的修饰键。
    ///
    /// 显示"空"不代表出错——什么都不按就是空。
    /// 但如果手势配了 Fn、这里一直显示"空"，那就是系统没把 Fn 报上来，
    /// 配了 Fn 的手势一条都不会命中。
    private var modifiersText: String {
        guard frames > 0 else { return "—" }
        return modifiers.isEmpty ? "无" : ModifierKey.describe(modifiers)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var statusText: String {
        guard running else {
            // 没启用的触摸板手势 = 引擎本来就该是停的，这不是故障
            return model.trackpadNeeded ? "引擎未运行" : "已停用（省资源）"
        }
        if frames > 0 { return "数据正常" }
        return "等待触点"
    }

    private var statusColor: Color {
        guard running else {
            // 没有启用的触摸板手势时引擎本来就是停的，这是灰色不是警告色
            return model.trackpadNeeded ? .orange : Theme.secondaryText
        }
        return frames > 0 ? .green : .orange
    }

    private var hintText: String {
        if !running && !model.trackpadNeeded {
            let reason = model.store.settings.engineEnabled
                ? "当前没有启用的触摸板手势"
                : "总开关已关闭"
            return "\(reason)，触摸板引擎已停用：不加载触控板设备、不跑定时器、不写诊断日志。"
                + "新建或启用一条触摸板手势后会自动启动，这里也会立刻开始计数。"
        }
        return "现在用手指在触控板上点一下或划一下：帧数开始涨就说明触控板数据正常，"
            + "没涨就是系统没把触点送进来（多见于授权没生效）。"
    }
}
