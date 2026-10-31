import SwiftUI
import AppKit

// ============================================================
// 应用选择器
//
// 三种用途：
//   .single          —— 从已安装应用里挑一个，加成一个作用域
//   .group 新建      —— 命名 + 多选，建成「应用组」（如"浏览器"装 Safari + Chrome）
//   .group 编辑      —— 传 editing，预填组名与成员，保存时就地改写
//
// 编辑模式补的是这里原来最大的窟窿：组建好之后成员定死，想加人或踢人只能把
// 整个组删了重建、再把它名下的手势一条条指回新组。
//
// 枚举 .app 放在后台线程做：/Applications 下有几百个包，
// 在主线程扫会让 sheet 出现明显卡顿。
// ============================================================

struct AppPickerSheet: View {
    enum Mode {
        case single
        case group
    }

    @ObservedObject var model: AppModel
    let mode: Mode
    /// 非 nil = 编辑已有的应用组
    let editing: ScopeEntry?
    var onClose: () -> Void

    @State private var apps: [InstalledApp] = []
    @State private var isLoading = true
    @State private var search = ""
    @State private var selected: Set<String> = []
    @State private var groupName = ""
    /// 徽章区实际占的高度，由 FlowLayout 自己量出来（见 selectedSection）
    @State private var chipHeight: CGFloat = 26
    /// 徽章区最多长到这么高，再多就滚
    private let chipMaxHeight: CGFloat = 64

    init(model: AppModel, mode: Mode, editing: ScopeEntry? = nil, onClose: @escaping () -> Void) {
        self.model = model
        self.mode = mode
        self.editing = editing
        self.onClose = onClose
        _groupName = State(initialValue: editing?.name ?? "")
        _selected = State(initialValue: Set(editing?.bundleIDs ?? []))
    }

    private var isEditing: Bool { editing != nil }

    private var filtered: [InstalledApp] {
        let keyword = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(keyword)
            || $0.bundleID.localizedCaseInsensitiveContains(keyword)
        }
    }

    private var canCommit: Bool {
        switch mode {
        case .single: return selected.count == 1
        case .group:  return !groupName.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider().opacity(0.5)

            if mode == .group {
                HStack(spacing: 8) {
                    Text("组名")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                    TextField("例如：浏览器", text: $groupName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                selectedSection
            }

            searchField
            Divider().opacity(0.4)

            if isLoading {
                Spacer()
                ProgressView().controlSize(.small)
                Text("正在扫描已安装应用…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 8)
                Spacer()
            } else {
                list
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 460, height: 560)
        .task { await loadApps() }
    }

    private var titleBar: some View {
        HStack {
            Text(titleText)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }

    private var titleText: String {
        switch mode {
        case .single: return "添加应用"
        case .group:  return isEditing ? "编辑应用组" : "新建应用组"
        }
    }

    private var commitTitle: String {
        switch mode {
        case .single: return "添加"
        case .group:  return isEditing ? "保存" : "创建"
        }
    }

    /// 组名下面常驻一行"已经选了哪几个"。
    ///
    /// 以前只靠列表里的对勾，勾完往下一滚就看不见自己选了什么，
    /// 保存前想核对一遍得来回滚动找。
    private var selectedSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text("已选")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Text("\(selected.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(selected.isEmpty ? Theme.secondaryText : Theme.accent)
                Spacer()
                if !selected.isEmpty {
                    Button("全部清空") { selected.removeAll() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                }
            }

            if selected.isEmpty {
                Text("还没有选择应用，在下面勾选即可加入这个组。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            } else {
                // 🔴 高度要按徽章实际占的行走，不能只写 .frame(maxHeight: 64)。
                // ScrollView 在垂直方向是贪婪的，给了 64 就吃掉 64 —— 只有一行徽章时
                // 底下白留 40 多点，看着像"中间空了一块"。
                ScrollView(.vertical) {
                    FlowLayout(spacing: 5) {
                        ForEach(selected.sorted(), id: \.self) { bundleID in
                            memberChip(bundleID)
                        }
                    }
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ChipStackHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                }
                .frame(height: min(max(chipHeight, 1), chipMaxHeight))
                .scrollDisabled(chipHeight <= chipMaxHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .onPreferenceChange(ChipStackHeightKey.self) { chipHeight = $0 }
    }

    private func memberChip(_ bundleID: String) -> some View {
        let app = apps.first { $0.bundleID == bundleID }
        // 🔴 扫描没结束时 apps 还是空的，这时候不能把成员当成"已卸载"：
        // 一打开面板满屏 com.google.Chrome 配问号文件夹，看着像全都没了。
        let pending = isLoading && app == nil
        return HStack(spacing: 4) {
            if let app {
                Image(nsImage: InstalledApps.icon(forPath: app.path))
                    .resizable()
                    .frame(width: 13, height: 13)
            } else if pending {
                // 占位撑住宽度，免得名字在扫描完成那一刻左右跳一下
                Color.clear.frame(width: 13, height: 13)
            } else {
                // 已卸载的成员也得显示出来，否则用户永远不知道它在组里
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.secondaryText)
            }
            Text(pending ? "读取中…" : (app?.name ?? bundleID))
                .font(.system(size: 10.5))
                .foregroundStyle(pending ? Theme.secondaryText : Color.primary)
                .lineLimit(1)
            Button {
                selected.remove(bundleID)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color(nsColor: .quaternaryLabelColor).opacity(app == nil ? 0.10 : 0.16))
        )
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            TextField("搜索应用", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filtered) { app in
                    row(app)
                }
                if filtered.isEmpty {
                    Text("没有匹配的应用")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .padding(.top, 30)
                }
            }
            .padding(8)
        }
    }

    private func row(_ app: InstalledApp) -> some View {
        let isSelected = selected.contains(app.bundleID)
        return Button {
            switch mode {
            case .single:
                selected = [app.bundleID]
            case .group:
                if isSelected { selected.remove(app.bundleID) } else { selected.insert(app.bundleID) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(nsImage: InstalledApps.icon(forPath: app.path))
                    .resizable()
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                    Text(app.bundleID)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 13))
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("取消") { onClose() }
                .keyboardShortcut(.cancelAction)
            Button(commitTitle) { commit() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCommit)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // MARK: - 动作

    private func loadApps() async {
        let scanned = await Task.detached(priority: .userInitiated) {
            InstalledApps.scan()
        }.value
        apps = scanned
        isLoading = false
    }

    private func commit() {
        switch mode {
        case .single:
            guard let bundleID = selected.first,
                  let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
            let scope = model.store.addAppScope(name: app.name, bundleID: app.bundleID)
            model.selectedScopeID = scope.id

        case .group:
            let name = groupName.trimmingCharacters(in: .whitespaces)
            // 排序保存：Set 的遍历顺序每次都不一样，落盘后配置会无意义地抖动
            let members = selected.sorted()
            if let editing {
                model.store.updateGroupScope(id: editing.id, name: name, bundleIDs: members)
                model.selectedScopeID = editing.id
            } else {
                let scope = model.store.addGroupScope(name: name, bundleIDs: members)
                model.selectedScopeID = scope.id
            }
        }
        model.clearSelection()
        onClose()
    }
}

// ============================================================
// 简易流式布局：徽章按行排，放不下就换行
//
// 用 Layout 而不是 LazyVGrid：应用名长短差很多（"Safari" 和
// "Visual Studio Code"），网格会按最宽的那个等分列，短名字后面留一大片空白。
// ============================================================

/// 量徽章流实际占了多高。ScrollView 会给满 maxHeight，靠这个值把它收回去。
private struct ChipStackHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let extra = rowWidth == 0 ? size.width : rowWidth + spacing + size.width
            if extra > maxWidth, rowWidth > 0 {
                widestRow = max(widestRow, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth = extra
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : widestRow, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
