import Foundation

// ============================================================
// 本地帮助文档
//
// 一个随包分发的 HTML（`Resources/Help/help.html`，打包时拷进
// `Contents/Resources/Help/`）。不联网、不依赖任何外部服务，离线可看。
//
// 两级查找：先找 app 包里的，再找仓库里的——
// `build-app.sh` 是在仓库根目录跑 `--selftest` 的，那时还没有 app 包，
// 只能落到第二级，否则自检会误报"帮助文档不存在"。
// ============================================================

enum HelpDocument {
    static let fileName = "help"
    static let fileExtension = "html"
    static let subdirectory = "Help"

    /// 仓库里的源文件路径（开发 / 自检用）
    static var sourceURL: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources")
            .appendingPathComponent(subdirectory)
            .appendingPathComponent("\(fileName).\(fileExtension)")
    }

    static var url: URL? {
        if let bundled = Bundle.main.url(forResource: fileName,
                                         withExtension: fileExtension,
                                         subdirectory: subdirectory) {
            return bundled
        }
        let dev = sourceURL
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    static var html: String? {
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
