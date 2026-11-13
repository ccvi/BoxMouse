import SwiftUI
import WebKit

// ============================================================
// 帮助面板
//
// 点「关于」页的「使用帮助」弹这个 sheet，内容是随包分发的本地 HTML。
// 用 WKWebView 而不是把文案写进 SwiftUI：文档要能排版（表格、代码块、
// 折叠式小节），而且以后改文档只要动 HTML，不用重新编译。
// ============================================================

struct HelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "book")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Text("使用帮助")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 12)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider()

            if let url = HelpDocument.url {
                HelpWebView(url: url)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.secondaryText)
                    Text("没找到帮助文档")
                        .font(.system(size: 12.5))
                    Text("预期位置：应用包内的 Resources/Help/help.html")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 540, idealHeight: 620)
    }
}

private struct HelpWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.allowsBackForwardNavigationGestures = false
        // 只放行这一个目录，文档里引用的相对资源也在这个范围内
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
