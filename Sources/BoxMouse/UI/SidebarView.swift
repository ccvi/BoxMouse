import SwiftUI
import AppKit

// ============================================================
// 左侧「作用域」
//
// 结构固定为三层：全局 → 应用组 → 应用。
// 全局永远排第一且不可删除；应用组和应用是用户加的，右键可移除。
// ============================================================

struct SidebarView: View {
    @ObservedObject var model: AppModel

    @State private var showAppPicker = false
    @State private var showGroupPicker = false
    @State private var hoveredScopeID: UUID?

    private var groups: [ScopeEntry] {
        model.store.scopes.filter { $0.kind == .group }
    }

    private var apps: [ScopeEntry] {
        model.store.scopes.filter { $0.kind == .app }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    scopeRow(model.store.globalScope)

                    if !groups.isEmpty {
                        sectionHeader("应用组")
                        ForEach(groups) { scopeRow($0) }
                    }
                    if !apps.isEmpty {
                        sectionHeader("应用")
                        ForEach(apps) { scopeRow($0) }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            Divider().opacity(0.5)
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAppPicker) {
            AppPickerSheet(model: model, mode: .single) { showAppPicker = false }
        }
        .sheet(isPresented: $showGroupPicker) {
            AppPickerSheet(model: model, mode: .group) { showGroupPicker = false }
        }
        .sheet(item: $model.editingGroup) { group in
            AppPickerSheet(model: model, mode: .group, editing: group) {
                model.editingGroup = nil
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("作用域")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
        }
        .frame(height: 40)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.leading, 12)
            .padding(.top, 12)
            .padding(.bottom, 4)
    }

    private func scopeRow(_ scope: ScopeEntry) -> some View {
        let isSelected = model.selectedScopeID == scope.id
        let count = model.store.gestureCount(scopeID: scope.id)
        return Button {
            model.selectedScopeID = scope.id
            model.clearSelection()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: scope.symbolName)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.accent : Theme.secondaryText)
                Text(scope.name)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)

                // 悬停时把计数让给编辑按钮：宽度固定，行内容不会左右跳
                if scope.kind == .group && hoveredScopeID == scope.id {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 20, alignment: .trailing)
                        .contentShape(Rectangle())
                        // 不用嵌套 Button：内外两层抢点击，容易连带把行也选中再打开 sheet
                        .onTapGesture { model.editingGroup = scope }
                        .help("编辑组成员")
                } else {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 20, alignment: .trailing)
                }
            }
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                hoveredScopeID = scope.id
            } else if hoveredScopeID == scope.id {
                hoveredScopeID = nil
            }
        }
        .contextMenu {
            if scope.kind == .group {
                Button("编辑应用组…") { model.editingGroup = scope }
                Divider()
            }
            if scope.kind != .global {
                Button("移除作用域", role: .destructive) {
                    model.store.removeScope(id: scope.id)
                    if model.selectedScopeID == scope.id {
                        model.selectedScopeID = model.store.globalScope.id
                    }
                }
            } else {
                Text("全局作用域不可移除")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    showAppPicker = true
                } label: {
                    Label("添加应用…", systemImage: "app.badge")
                }
                Button {
                    showGroupPicker = true
                } label: {
                    Label("新建应用组…", systemImage: "square.stack.3d.up")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                    Text("添加")
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.10))
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }
}
