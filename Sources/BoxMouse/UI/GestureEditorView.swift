import SwiftUI
import AppKit

// ============================================================
// 手势编辑器（sheet）
//
// 表单顺序跟着"人的思考顺序"走：叫什么 → 画成什么样 → 怎么触发 → 触发后干什么 → 作用在哪儿。
// 保存按钮只有在「名称非空 + 有轨迹 + 动作填全」时才可用，
// 半成品手势进了库只会让用户以后自己困惑。
// ============================================================

struct GestureEditorView: View {
    @ObservedObject var model: AppModel
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Gesture

    init(model: AppModel, draft: Gesture, isNew: Bool) {
        self.model = model
        self.isNew = isNew
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
        && draft.path.count > 1
        && draft.action.isValid
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新建鼠标手势" : "编辑鼠标手势")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    nameSection
                    pathSection
                    triggerSection
                    ActionEditorSection(action: $draft.action)
                    ScopeHintLine(model: model, scopeID: draft.scopeID)
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            footer
        }
        // 高度按内容实测定的：轨迹框 200 + 修饰键一整行之后，655 会把说明挤掉。
        .frame(width: 580, height: 692)
    }

    // MARK: - 名称

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "名称")
            TextField("给这条手势起个名字", text: $draft.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
        }
    }

    // MARK: - 轨迹

    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "轨迹")
                Spacer()
                if !draft.path.isEmpty {
                    Text(PathRecognizer.directionString(draft.path))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                    Button("清除") {
                        draft.path = []
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            PathCaptureView(template: draft.path) { points in
                draft.path = PathRecognizer.normalize(points)
                draft.rawPath = points.map { PathPoint($0) }
            }
            // 框不能太扁：宽高比 4:1 时用户从上往下画"竖线"，手一漂就是 20% 的斜，
            // 再被归一化的短轴放大一次，看着就成了"又斜又竖"。200 高能把漂移压到 10% 以内。
            .frame(height: 200)

            Text("在框内按住鼠标拖动即可重新绘制；松手后轨迹自动保存。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    // MARK: - 触发键与修饰键

    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "触发键")
                    Picker("", selection: $draft.trigger) {
                        ForEach(GestureTrigger.allCases) { trigger in
                            Text(trigger.displayName).tag(trigger)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "作用域")
                    Picker("", selection: $draft.scopeID) {
                        ForEach(model.store.scopes) { scope in
                            Text(scope.name).tag(scope.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "修饰键")
                ModifierKeyChips(selection: $draft.modifiers)
                Text("不选表示直接用手势触发；选了就得同时按住才生效。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
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
