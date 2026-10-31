import SwiftUI
import AppKit

// ============================================================
// 手势列表
//
// 布局对齐参考图：头部（作用域名 + 添加）→ 筛选条 → 表头 → 行 → 底部操作条。
// 行不能用 SwiftUI 的 List：它自带选中态、分隔线和内边距，
// 想做出参考图那种"隔行淡灰、圆角、可多选"的效果反而要一路关掉默认行为。
// ============================================================

struct GestureListView: View {
    @ObservedObject var model: AppModel

    @State private var hoveredID: UUID?
    @State private var showTestSheet = false
    @State private var showResetConfirm = false

    private var gestures: [Gesture] { model.visibleGestures }

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
            tableHeader
            Divider().opacity(0.4)
            rows
            Divider().opacity(0.5)
            footer
        }
        .background(Theme.contentBackground)
        .sheet(isPresented: $showTestSheet) {
            GestureTestSheet(model: model) { showTestSheet = false }
        }
        .confirmationDialog("恢复默认手势？",
                            isPresented: $showResetConfirm) {
            Button("恢复默认", role: .destructive) {
                model.store.seedDefaults()
                model.clearSelection()
                model.showToast("已恢复出厂手势")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前所有手势和作用域都会被替换成出厂示例，此操作不可撤销。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.selectedScope.symbolName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
            Text(model.selectedScope.name)
                .font(.system(size: 16, weight: .semibold))
            Text("\(gestures.count)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .padding(.leading, 2)

            // 应用组的成员只有建组那次能选，这里必须给一个看得见的入口，
            // 否则用户只会想到"右键 → 移除作用域"，把整个组连带手势删掉
            if model.selectedScope.kind == .group {
                Button {
                    model.editingGroup = model.selectedScope
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 9, weight: .medium))
                        Text("成员")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .help("编辑这个组包含哪些应用")
            }

            Spacer()

            Toggle(isOn: Binding(
                get: { model.store.settings.engineEnabled },
                set: { model.store.settings.engineEnabled = $0 }
            )) {
                Text("启用手势").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Menu {
                Button("新建鼠标手势") { model.beginCreate(kind: .mouse) }
                Button("新建触摸板手势") { model.beginCreate(kind: .trackpad) }
                    // 本机没有可用触控板接口时不给点，免得建出一条永远触发不了的记录
                    .disabled(!TrackpadEngine.isAvailable)
                Button("新建快捷键") { model.beginCreate(kind: .shortcut) }
                // 菜单里只放这三条能真点的东西。
                // 曾经还挂着「恢复配置」（语义像导入手势）和一条永远置灰的
                // 「添加应用作用域」（点了没反应，纯粹占地方），都撤了：
                // 备份/恢复在「通用 → 配置」，加作用域在左侧栏的「作用域」标题旁边。
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .semibold))
                    Text("添加").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent)
                )
                .foregroundStyle(.white)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    // MARK: - 筛选条

    private var filterBar: some View {
        HStack(spacing: 10) {
            searchField

            PillSegmented(options: EnabledFilter.allCases.map { ($0, $0.title) },
                          selection: $model.enabledFilter)

            Menu {
                // 四档都是实打实的 case，不再用 nil 表示"全部"。
                // 当前选中哪一档看按钮上的文字就够了，菜单里不再画勾选标记：
                // Menu 内嵌套 Label/图标在不同系统版本上排版会飘，不值得为它冒风险。
                ForEach(GestureKindFilter.allCases) { filter in
                    Button(filter.title) { model.kindFilter = filter }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.kindFilter.title)
                        .font(.system(size: 12))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
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

            Spacer()

            Text("已选 \(model.selectionInView.count) / 显示 \(gestures.count)")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
            TextField("搜索名称、动作…", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 220, height: 26)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Theme.hairline, lineWidth: 1)
        )
    }

    // MARK: - 表头

    private var tableHeader: some View {
        HStack(spacing: 0) {
            Text("启用").frame(width: Theme.columnEnabled, alignment: .center)
            Text("轨迹").frame(width: Theme.columnPath, alignment: .center)
            sortHeader("名称", key: .name)
                .frame(width: Theme.columnName, alignment: .leading)
            sortHeader("触发键", key: .trigger)
                .frame(width: Theme.columnTrigger, alignment: .leading)
            Text("动作")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("范围").frame(width: Theme.columnScope, alignment: .leading)
            Spacer().frame(width: 12)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }

    private func sortHeader(_ title: String, key: SortKey) -> some View {
        Button {
            if model.sortKey == key {
                model.ascending.toggle()
            } else {
                model.sortKey = key
                model.ascending = true
            }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .foregroundStyle(model.sortKey == key ? Color.primary : Theme.secondaryText)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 行

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(gestures.enumerated()), id: \.element.id) { index, gesture in
                    row(gesture, index: index)
                }
                if gestures.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.draw")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.secondaryText.opacity(0.6))
            Text(model.searchText.isEmpty ? "这个作用域还没有手势" : "没有匹配的手势")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            if model.searchText.isEmpty {
                Button("新建一条") { model.beginCreate() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func row(_ gesture: Gesture, index: Int) -> some View {
        let isSelected = model.selection.contains(gesture.id)
        let isHovered = hoveredID == gesture.id

        return HStack(spacing: 0) {
            RowCheckbox(isOn: gesture.enabled) {
                model.store.setEnabled(!gesture.enabled, ids: [gesture.id])
            }
            .frame(width: Theme.columnEnabled, alignment: .center)

            // 触摸板手势没有轨迹可画，用它的形态图标顶上这一列，
            // 否则会显示成一片空白，看着像没配好；快捷键同理，用键盘图标占位
            if gesture.kind == .trackpad {
                Image(systemName: gesture.trackpad?.pattern.symbolName ?? "hand.tap")
                    .font(.system(size: 15))
                    .foregroundStyle(gesture.enabled ? Theme.accent : Theme.secondaryText)
                    .frame(width: Theme.columnPath, alignment: .center)
            } else if gesture.kind == .shortcut {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
                    .foregroundStyle(gesture.enabled ? Theme.accent : Theme.secondaryText)
                    .frame(width: Theme.columnPath, alignment: .center)
            } else {
                PathThumbnail(path: gesture.path,
                              tint: gesture.enabled ? .primary : Theme.secondaryText)
                    .frame(width: Theme.columnPath, alignment: .center)
            }

            Text(gesture.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .foregroundStyle(gesture.enabled ? Color.primary : Theme.secondaryText)
                .frame(width: Theme.columnName, alignment: .leading)

            // 带修饰键的手势要能一眼分出来：⌘ + 右键 / 右键
            Text(gesture.triggerDescription)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: Theme.columnTrigger, alignment: .leading)

            Text(gesture.action.summary)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(model.store.scopeName(id: gesture.scopeID))
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundStyle(Theme.secondaryText)
                .frame(width: Theme.columnScope, alignment: .leading)

            Spacer().frame(width: 12)
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.rowCorner, style: .continuous)
                .fill(background(isSelected: isSelected, isHovered: isHovered, index: index))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredID = hovering ? gesture.id : (hoveredID == gesture.id ? nil : hoveredID)
        }
        .onTapGesture(count: 2) {
            model.beginEdit(gesture)
        }
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                model.toggleSelection(gesture.id)
            } else {
                model.selection = [gesture.id]
            }
        }
        .contextMenu {
            Button("编辑…") { model.beginEdit(gesture) }
            Button(gesture.enabled ? "禁用" : "启用") {
                model.store.setEnabled(!gesture.enabled, ids: [gesture.id])
            }
            Button("复制") { model.store.duplicate(ids: [gesture.id]) }
            Divider()
            Button("删除", role: .destructive) { model.store.delete(ids: [gesture.id]) }
        }
    }

    private func background(isSelected: Bool, isHovered: Bool, index: Int) -> Color {
        if isSelected { return Theme.accentSoft }
        if isHovered { return Color(nsColor: .quaternaryLabelColor).opacity(0.07) }
        // 隔行淡灰，让长列表有节奏
        return index.isMultiple(of: 2) ? Color(nsColor: .quaternaryLabelColor).opacity(0.035) : .clear
    }

    // MARK: - 底部操作条

    private var footer: some View {
        HStack(spacing: 6) {
            ToolbarChip(title: "全选") { model.selectAllVisible() }
            ToolbarChip(title: "编辑", isEnabled: model.selectionInView.count == 1) {
                if let id = model.selectionInView.first,
                   let gesture = model.store.gestures.first(where: { $0.id == id }) {
                    model.beginEdit(gesture)
                }
            }
            ToolbarChip(title: "启用选中", isEnabled: !model.selectionInView.isEmpty) {
                model.setEnabledForSelection(true)
            }
            ToolbarChip(title: "禁用选中", isEnabled: !model.selectionInView.isEmpty) {
                model.setEnabledForSelection(false)
            }
            // 这条工具条只管「对选中的这些条目做什么」。
            // 备份曾经也在这儿，但它跟选中什么无关（整机配置），
            // 混在一排选中操作里容易被读成"备份选中的手势"。已撤。
            ToolbarChip(title: "删除",
                        tint: Color(red: 0.85, green: 0.20, blue: 0.18),
                        isEnabled: !model.selectionInView.isEmpty) {
                model.deleteSelected()
            }

            Spacer()

            ToolbarChip(title: "手势测试", symbol: "scribble") { showTestSheet = true }
            ToolbarChip(title: "恢复默认") { showResetConfirm = true }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
    }
}
