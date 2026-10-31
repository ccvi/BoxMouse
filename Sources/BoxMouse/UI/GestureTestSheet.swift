import SwiftUI

// ============================================================
// 手势测试
//
// 不依赖辅助功能授权也能用：在框里画一笔，直接算出与现有全部手势的相似度。
// 调阈值、改模板、验证"我画的和它存的到底像不像"都靠这个面板。
// ============================================================

struct GestureTestSheet: View {
    @ObservedObject var model: AppModel
    var onClose: () -> Void

    @State private var path: [PathPoint] = []
    @State private var results: [(gesture: Gesture, score: Double)] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("手势测试")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !path.isEmpty {
                    Button("重画") {
                        path = []
                        results = []
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 48)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                PathCaptureView(template: path) { points in
                    path = PathRecognizer.normalize(points)
                    evaluate()
                }
                .frame(height: 170)

                Text("画完后立即比对全部手势，相似度低于 \(Int(PathRecognizer.matchThreshold * 100))% 视为不匹配。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(20)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 4) {
                    if results.isEmpty {
                        Text(path.isEmpty ? "还没有轨迹" : "没有候选手势")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 24)
                    }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, item in
                        resultRow(item.gesture, score: item.score)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 220)

            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("关闭") { onClose() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
        }
        .frame(width: 480, height: 560)
    }

    private func resultRow(_ gesture: Gesture, score: Double) -> some View {
        let passed = score >= PathRecognizer.matchThreshold
        return HStack(spacing: 10) {
            PathThumbnail(path: gesture.path, showsFrame: false)
                .frame(width: 56, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(gesture.name)
                    .font(.system(size: 12, weight: passed ? .semibold : .regular))
                Text("\(gesture.trigger.displayName) · \(gesture.action.summary)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            Text(String(format: "%.0f%%", score * 100))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(passed ? Theme.accent : Theme.secondaryText)
            Image(systemName: passed ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 12))
                .foregroundStyle(passed ? Color.green : Theme.secondaryText.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(passed ? Theme.accentSoft : Color(nsColor: .quaternaryLabelColor).opacity(0.05))
        )
    }

    private func evaluate() {
        let scored = model.store.gestures
            .filter { !$0.path.isEmpty && $0.enabled }
            .map { (gesture: $0, score: PathRecognizer.score(path, $0.path)) }
            .sorted { $0.score > $1.score }
        results = Array(scored.prefix(5))
    }
}
