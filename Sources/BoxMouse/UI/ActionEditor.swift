import SwiftUI
import AppKit

// ============================================================
// 动作编辑器（鼠标手势 / 触摸板手势共用）
//
// 抽出来的原因很具体：两种手势只有"怎么触发"不同，动作、作用域、
// 名称完全一样。复制一份意味着以后加动作类型要改两处，迟早漏。
// ============================================================

struct ActionEditorSection: View {
    @Binding var action: GestureAction

    @State private var apps: [InstalledApp] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "动作")
            HStack(spacing: 10) {
                Picker("", selection: $action.kind) {
                    ForEach(ActionKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 160, alignment: .leading)

                detail
            }
        }
        .task {
            apps = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch action.kind {
        case .keystroke:
            ShortcutRecorder(combo: $action.keyCombo)

        case .openApp:
            Menu {
                ForEach(apps) { app in
                    Button(app.name) {
                        action.appPath = app.path
                        action.appName = app.name
                    }
                }
                Divider()
                Button("浏览…") { chooseApp() }
            } label: {
                HStack(spacing: 6) {
                    Text(action.appName ?? "选择应用")
                        .font(.system(size: 12))
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

        case .openURL:
            TextField("https://example.com", text: Binding(
                get: { action.urlString ?? "" },
                set: { action.urlString = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))

        case .media:
            Picker("", selection: Binding(
                get: { action.mediaKey ?? .playPause },
                set: { action.mediaKey = $0 }
            )) {
                ForEach(MediaKey.allCases) { key in
                    Text(key.displayName).tag(key)
                }
            }
            .labelsHidden()
            .fixedSize()

        case .window:
            Picker("", selection: Binding(
                get: { action.windowOp ?? .minimize },
                set: { action.windowOp = $0 }
            )) {
                ForEach(WindowOp.allCases) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()

        case .browser:
            Picker("", selection: Binding(
                get: { action.browserOp ?? .back },
                set: { action.browserOp = $0 }
            )) {
                ForEach(BrowserOp.allCases) { op in
                    Text(op.displayName).tag(op)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        action.appPath = url.path
        action.appName = (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}

/// 作用域说明。两个编辑器也共用。
struct ScopeHintLine: View {
    @ObservedObject var model: AppModel
    let scopeID: UUID

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(Theme.secondaryText)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var text: String {
        let scope = model.store.scope(id: scopeID)
        switch scope?.kind {
        case .app, .group:
            return "仅当指针所在的应用属于「\(scope?.name ?? "")」时这条手势才会生效，同形状的全局手势会被它优先命中。"
        default:
            return "全局手势在任何应用里都生效；为某个应用单独建的手势会优先于全局。"
        }
    }
}

// ============================================================
// 快捷键录制
//
// 「点一下 → 按下组合键 → 记下来」。用 local monitor 而不是自定义 NSView：
// 自定义视图要处理 firstResponder、失去焦点、和 sheet 抢键盘，而 local monitor
// 只在录制态挂上，停止录制就摘掉，不会影响别处的输入。
// ============================================================

struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?

    @State private var isRecording = false
    @State private var monitor: Any?
    /// 录到了一个不接受的组合（同时按了两个以上修饰键）时的当场反馈。
    /// 默默吞掉按键最糟：用户会以为自己没按对，反复按，最后也不知道到底哪条不行。
    @State private var rejected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                HStack(spacing: 6) {
                    Text(isRecording ? "按下组合键…" : (combo?.display ?? "未设置"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(isRecording ? Theme.accent : Color.primary)
                    Image(systemName: isRecording ? "record.circle.fill" : "record.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(isRecording ? Theme.accent : Theme.secondaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(rejected ? Color.orange : (isRecording ? Theme.accent : Theme.hairline),
                                lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(isRecording ? "按 Esc 取消" : "点击后按下要录制的组合键")
            .onDisappear { stopRecording() }

            if rejected {
                Text("最多按两个修饰键（⌘⌥⌃⇧ 里选一个或两个）")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        rejected = false
        // 录制期间引擎必须放行键盘：否则录一个已存在的组合键会当场执行旧动作
        ShortcutCapture.isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc 永远留给"取消录制"，不能录成 ⌘ 的 Esc
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            let flags = KeyCombo.cgFlags(from: event.modifierFlags)
            let name = KeyName.display(keyCode: event.keyCode)
            guard !name.isEmpty else { return nil }

            let candidate = KeyCombo(keyCode: event.keyCode,
                                     flags: flags.rawValue,
                                     display: KeyCombo.symbols(for: flags) + name)
            // 超过两个修饰键：不接受，但**别退出录制**——用户下一把按对了还要能直接录上
            if candidate.shortcutModifierCount > 2 {
                rejected = true
                return nil
            }
            rejected = false
            combo = candidate
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        ShortcutCapture.isRecording = false
    }
}

extension KeyCombo {
    /// NSEvent 的修饰键 → CGEventFlags。
    /// 只取这四位：event.modifierFlags 里还有 capsLock、numericPad 之类，直接转会带上噪音。
    static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option)  { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift)   { result.insert(.maskShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }

    /// 按 Apple 的书写顺序拼修饰键：⌃⌥⇧⌘
    static func symbols(for flags: CGEventFlags) -> String {
        var out = ""
        if flags.contains(.maskControl)    { out += "⌃" }
        if flags.contains(.maskAlternate)  { out += "⌥" }
        if flags.contains(.maskShift)      { out += "⇧" }
        if flags.contains(.maskCommand)    { out += "⌘" }
        return out
    }
}

enum KeyName {
    /// 虚拟键码 → 要显示的字。
    ///
    /// 字母数字不写死映射表：用 CGEvent + NSEvent 反查，**自动跟随用户的键盘布局**。
    /// 俄文键盘上按 A 键就该显示俄文字母，不是 "A"。
    static func display(keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        let source = CGEventSource(stateID: .hidSystemState)
        if let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
           let nsEvent = NSEvent(cgEvent: event),
           let chars = nsEvent.charactersIgnoringModifiers,
           !chars.isEmpty {
            return chars.uppercased()
        }
        return "键\(keyCode)"
    }

    /// 不能靠字符表示的键。键码是 macOS 的虚拟键位，跟键盘布局无关。
    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

// ============================================================
// 修饰键（两个编辑器共用）
//
// 语义对鼠标和触摸板完全一样：**叠加在触发条件上的门槛**，不是另一种触发方式。
// 做成可多选的方块而不是下拉：⌘⇧ 这类组合真的会用，5 个键一屏看全比展开下拉快。
// ============================================================

struct ModifierKeyChips: View {
    @Binding var selection: Set<ModifierKey>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(ModifierKey.allCases) { key in
                let on = selection.contains(key)
                Button {
                    if on { selection.remove(key) } else { selection.insert(key) }
                } label: {
                    Text(key.symbol)
                        // 13 号下 ⌘⌥⌃⇧ 笔画太细，混在灰底里看不清
                        .font(.system(size: 14.5, weight: .medium))
                        .frame(width: 34, height: 25)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(on ? Theme.accent
                                          : Color(nsColor: .quaternaryLabelColor).opacity(0.16))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(on ? Color.clear : Theme.hairline, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help(key.displayName)
            }

            if !selection.isEmpty {
                Button("清空") { selection.removeAll() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
                    .padding(.leading, 2)
            }

            Spacer()
        }
    }
}
