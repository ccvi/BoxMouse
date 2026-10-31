import SwiftUI

// ============================================================
// 主界面骨架：顶部标签栏 + 内容区
//
// 窗口是 .fullSizeContentView + 隐藏标题，所以内容从窗口最顶部开始。
// 左侧要给红绿灯按钮留出位置（78pt），否则标签栏会被压住。
// ============================================================

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider().opacity(0.5)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.windowBackground)
        // 让内容顶到窗口最上沿，标签栏才和红绿灯在同一行（对齐参考图）
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) { toastView }
        .sheet(item: $model.editingGesture) { gesture in
            // 三种触发方式用三个编辑器：鼠标手势要画轨迹，触摸板手势只选
            // 手指数和形态，快捷键连轨迹和手指数都没有。硬塞进同一个表单
            // 会让大半控件永远是无关的。
            switch gesture.kind {
            case .trackpad:
                TrackpadEditorView(model: model,
                                   draft: gesture,
                                   isNew: model.isCreatingGesture)
            case .shortcut:
                ShortcutEditorView(model: model,
                                   draft: gesture,
                                   isNew: model.isCreatingGesture)
            case .mouse:
                GestureEditorView(model: model,
                                  draft: gesture,
                                  isNew: model.isCreatingGesture)
            }
        }
    }

    // MARK: - 顶部标签

    private var tabBar: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 78)
            HStack(spacing: 2) {
                ForEach(MainTab.allCases) { tab in
                    tabButton(tab)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.10))
            )
            Spacer(minLength: 78)
        }
        .frame(height: 52)
        .padding(.top, 2)
    }

    private func tabButton(_ tab: MainTab) -> some View {
        let isSelected = model.selectedTab == tab
        return Button {
            model.selectedTab = tab
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? Color.primary : Theme.secondaryText)
            // 横向从 14 加到 17：文字两侧多留一点，点偏一点也还在按钮上
            .padding(.horizontal, 17)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
                    .shadow(color: .black.opacity(isSelected ? 0.10 : 0), radius: 3, y: 1)
            )
            // 可视高度 30，可点高度 36：原来标签只有 28 高、顶栏 52，
            // 上下各留 12pt 死区，用户反馈"有时候点不到"。多出来的是透明边，
            // 视觉上仍然是小胶囊，但手指/指针落在胶囊边缘外一点也算点中。
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch model.selectedTab {
        case .gestures:
            GestureTabView(model: model)
        case .general:
            GeneralView(model: model)
        case .permissions:
            PermissionsView(model: model)
        case .about:
            AboutView()
        }
    }

    // MARK: - 轻提示

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(Color.black.opacity(0.78))
                )
                .padding(.bottom, 26)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeOut(duration: 0.18), value: toast)
        }
    }
}
