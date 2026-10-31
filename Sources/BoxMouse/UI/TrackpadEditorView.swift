import SwiftUI
import AppKit

// ============================================================
// 触摸板手势编辑器（sheet）
//
// 跟鼠标手势编辑器分开写：那边的核心是"画一笔"，这边是"选条件和方向"，
// 表单结构完全不同。硬合成一个会有一半控件永远用不上。
// ============================================================

struct TrackpadEditorView: View {
    @ObservedObject var model: AppModel
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Gesture

    init(model: AppModel, draft: Gesture, isNew: Bool) {
        self.model = model
        self.isNew = isNew
        _draft = State(initialValue: draft)
    }

    /// 当前触发条件。老数据或新建时缺省给「3 指轻点」。
    private var spec: TrackpadSpec {
        draft.trackpad ?? .tap(fingers: 3)
    }

    /// 单指只留「轻点」和「画轨迹」：一根手指在触控板上就是移动指针，
    /// 滑动/捏合都不可能由单指完成，列出来只会造出永不触发的配置。
    private var availablePatterns: [TrackpadPattern] {
        spec.fingers <= 1 ? [.tap, .path] : TrackpadPattern.allCases
    }

    /// 画轨迹缺修饰键不许保存。
    ///
    /// 不按修饰键时，单指在触控板上就是在移动指针——每一段指针移动都会
    /// 攒成一条轨迹，抬手就触发动作，等于把整个触控板废掉。
    private var pathNeedsModifier: Bool {
        spec.pattern == .path && draft.modifiers.isEmpty
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && draft.action.isValid
            && !pathNeedsModifier
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isNew ? "新建触摸板手势" : "编辑触摸板手势")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !TrackpadEngine.isAvailable {
                    Label("本机不可用", systemImage: "exclamationmark.triangle")
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
                    trackpadSection
                    ActionEditorSection(action: $draft.action)
                    scopeSection
                }
                .padding(20)
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 520, height: 600)
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

    // MARK: - 触发条件

    private var trackpadSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "手指数")
                HStack(spacing: 6) {
                    ForEach([1, 2, 3, 4, 5], id: \.self) { count in
                        fingerChip(count)
                    }
                    Spacer()
                    if spec.pattern.fixesTwoFingers {
                        Text("捏合固定两指")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText)
                    } else if spec.pattern == .path {
                        Text("画轨迹固定单指")
                            .font(.system(size: 10.5))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "形态")
                HStack(spacing: 10) {
                    Picker("", selection: Binding(
                        get: { spec.pattern },
                        set: { pattern in update { $0.pattern = pattern } }
                    )) {
                        ForEach(availablePatterns) { pattern in
                            Text(pattern.displayName).tag(pattern)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160, alignment: .leading)

                    if spec.pattern == .swipe {
                        directionChips
                    }
                }
            }

            if spec.pattern == .path {
                pathSection
            }

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "修饰键")
                ModifierKeyChips(selection: $draft.modifiers)
                (Text("修饰键是") + Text("叠加条件").bold()
                 + Text("：必须") + Text("在手指落下之前").bold()
                 + Text("按住，中途按不算。"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if pathNeedsModifier {
                    Label("画轨迹必须选一个修饰键：不按修饰键时，单指每移动一下都会被当成在画轨迹。",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(hintText)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private func fingerChip(_ count: Int) -> some View {
        let on = spec.fingers == count
        let locked = (spec.pattern.fixesTwoFingers && count != 2)
                  || (spec.pattern == .path && count != 1)
        return Button {
            update { $0.fingers = count }
        } label: {
            Text("\(count)")
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 30, height: 25)
                .foregroundStyle(on ? Color.white : (locked ? Theme.secondaryText : Color.primary))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? Theme.accent
                                  : Color(nsColor: .quaternaryLabelColor).opacity(locked ? 0.07 : 0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(on ? Color.clear : Theme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .help("\(count) 根手指")
    }

    private var directionChips: some View {
        HStack(spacing: 6) {
            ForEach(SwipeDirection.allCases) { direction in
                let on = spec.direction == direction
                Button {
                    update { $0.direction = direction }
                } label: {
                    Image(systemName: direction.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 25)
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
                .help(direction.displayName)
            }
        }
    }

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

    /// 画轨迹的模板录入：和鼠标手势编辑器是同一个控件、同一套归一化。
    private var pathSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "轨迹")
                Spacer()
                if let template = spec.path, !template.isEmpty {
                    Text(PathRecognizer.directionString(template))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                    Button("清除") {
                        update { $0.path = []; $0.rawPath = [] }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            PathCaptureView(template: spec.path ?? []) { points in
                update {
                    $0.path = PathRecognizer.normalize(points)
                    $0.rawPath = points.map { PathPoint($0) }
                }
            }
            .frame(height: 160)

            Text("在框内按住鼠标画一条轨迹，松手后自动保存。触发时在触控板上单指画出相似的轨迹即可。")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    /// 改触发条件时顺手把矛盾字段修平（单指只剩轻点、捏合固定两指），
    /// 否则会存进一个自相矛盾的组合。
    private func update(_ transform: (inout TrackpadSpec) -> Void) {
        var next = spec
        transform(&next)
        draft.trackpad = next.sanitized()
    }

    /// 底部那句说明跟着当前条件走。单指是特例：它落在触控板上就是移动指针，
    /// 只能配轻点，得把"为什么形态不能选"讲清楚。
    private var hintText: String {
        if spec.pattern == .path {
            return "先按住修饰键，再用 1 根手指在触控板上画出相似的轨迹，抬手即触发；画的时候屏幕上会显示一条轨迹线。轨迹太短（不足约 3 厘米）不会触发。"
        }
        if spec.fingers == 1 {
            return draft.modifiers.isEmpty
                ? "单指轻点会被系统当成普通单击，系统自己也会响应——建议配一个修饰键（如 Fn）：先把 Fn 按住，再落指。"
                : "在触控板上用 1 根手指轻点即可触发；单指只支持轻点。记得先按住修饰键再落指。"
        }
        return "在触控板上用 \(spec.fingers) 根手指完成上面的动作即可触发。记得先按住修饰键再落指。"
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
