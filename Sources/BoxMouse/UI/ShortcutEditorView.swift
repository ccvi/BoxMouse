import SwiftUI

// ============================================================
// 快捷键编辑器（sheet）
//
// 第三个编辑器，和前两个依然分开写：这里没有轨迹、没有手指数，
// 整张表只有"录一个键 + 选个动作"。硬塞进任何一个现有编辑器都会
// 让大半个表单变成无关字段。
//
// 校验比另外两个严：一个录错的组合键能把整个键盘吃掉，所以
// 不能录就当场说清楚，而不是等用户保存完发现打字没反应。
// ============================================================

struct ShortcutEditorView: View {
    @ObservedObject var model: AppModel
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Gesture

    init(model: AppModel, draft: Gesture, isNew: Bool) {
        self.model = model
        self.isNew = isNew
        _draft = State(initialValue: draft)
    }

    private var combo: KeyCombo? { draft.hotkey }

    /// 一次按了三个以上修饰键：超出支持范围（最多两个）。
    private var tooManyModifiers: Bool {
        (combo?.shortcutModifierCount ?? 0) > 2
    }

    /// 裸键：既没有修饰键、也不是不产生字符的功能键。
    ///
    /// 不按修饰键的裸键一旦被注册成全局快捷键，全系统这个键就归我们了——
    /// 用户打字直接废掉，而且几乎不可能联想到是这个设置干的。
    private var bareKey: Bool {
        guard let combo else { return false }
        return combo.shortcutModifierCount == 0
            && !KeyCombo.functionKeyCodes.contains(combo.keyCode)
    }

    /// 同作用域下已经有同样的键 → 后者永远不会被命中，属于配置错误，必须拦住。
    private var duplicate: Gesture? {
        guard let combo else { return nil }
        return others.first { other in
            guard let key = other.hotkey,
                  key.keyCode == combo.keyCode,
                  CGEventFlags(rawValue: key.flags).intersection(KeyCombo.shortcutModifiers)
                    == CGEventFlags(rawValue: combo.flags).intersection(KeyCombo.shortcutModifiers)
            else { return false }
            return other.scopeID == draft.scopeID
        }
    }

    /// 全局已经占了这个键 → 本条（应用/分组作用域）照样生效，只是要让人知道
    /// 这属于"覆盖"，不是重复。这个用法是合理的，所以只提示、不拦。
    private var shadowedGlobal: Gesture? {
        guard let combo else { return nil }
        guard let scope = model.store.scope(id: draft.scopeID), scope.kind != .global else { return nil }
        return others.first { other in
            guard let key = other.hotkey,
                  key.keyCode == combo.keyCode,
                  CGEventFlags(rawValue: key.flags).intersection(KeyCombo.shortcutModifiers)
                    == CGEventFlags(rawValue: combo.flags).intersection(KeyCombo.shortcutModifiers),
                  model.store.scope(id: other.scopeID)?.kind == .global
            else { return false }
            return true
        }
    }

    /// 除自己以外的所有已启用快捷键。编辑态要排除自己，否则永远判定冲突。
    private var others: [Gesture] {
        model.store.gestures.filter { $0.id != draft.id && $0.kind == .shortcut && $0.enabled }
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.action.isValid
            && combo != nil
            && !tooManyModifiers
            && !bareKey
            && duplicate == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新建快捷键" : "编辑快捷键")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !model.store.settings.engineEnabled {
                    Label("手势引擎已关闭", systemImage: "pause.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameSection
                    shortcutSection
                    ActionEditorSection(action: $draft.action)
                    scopeSection
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 520, height: 470)
    }

    // MARK: - 名称

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "名称")
            TextField("给这条快捷键起个名字", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "快捷键")
                Spacer()
                if combo != nil {
                    Button("清除") { draft.hotkey = nil }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }

            ShortcutRecorder(combo: $draft.hotkey)

            if !model.keyboardAvailable {
                // 鼠标手势是好的，只有快捷键不灵——不说清楚就会被当成"功能坏了"
                Label("键盘监听没挂上（需要「输入监控」授权），这条快捷键保存后不会生效。鼠标手势不受影响。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if tooManyModifiers, let combo {
                Label("\(combo.display) 按了三个以上的修饰键。快捷键最多支持两个，请在 ⌘ / ⌥ / ⌃ / ⇧ 里留一个或两个重新录。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if bareKey, let combo {
                Label("\(combo.display) 不能单独做快捷键：没有修饰键的普通键会被系统级拦截，全系统这个键都归手势了。请按住 ⌘ / ⌥ / ⌃ / ⇧ 中的一个再录。",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let duplicate {
                Label("\(combo?.display ?? "") 已被同作用域的「\(duplicate.name)」占用，这一条永远轮不到触发。",
                      systemImage: "xmark.octagon.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let shadowedGlobal {
                Label("全局已有一条用 \(combo?.display ?? "") 的「\(shadowedGlobal.name)」。本条只在当前作用域里生效，会优先命中它。",
                      systemImage: "info.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("点一下左边按钮，然后按下要用的组合键：在 ⌘ / ⌥ / ⌃ / ⇧ 里按住一个或两个，再按一个键（F1–F20、方向键可以单独用）。\n录好之后这个键就归本应用，系统原本的同名快捷键不再生效；⌃⌥ + 方向键 / U I J K 是 macOS 自带的窗口平铺，建议避开。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 作用域

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "作用域")
            Picker("", selection: $draft.scopeID) {
                ForEach(model.store.scopes) { scope in
                    Text(scope.name).tag(scope.id)
                }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .leading)

            ScopeHintLine(model: model, scopeID: draft.scopeID)
                .padding(.top, 2)
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            if isNew {
                Text("新建后会立即生效")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "添加" : "保存") {
                model.commitEditing(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}
