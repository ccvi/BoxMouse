import SwiftUI

// ============================================================
// 手势页：左侧作用域 + 右侧手势表格
// ============================================================

struct GestureTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: Theme.sidebarWidth)
            Divider().opacity(0.5)
            GestureListView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
