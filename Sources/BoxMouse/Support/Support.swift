import AppKit
import Carbon.HIToolbox

// ============================================================
// 通用工具：颜色、键名、已安装应用枚举
// ============================================================

extension NSColor {
    convenience init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }

    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#FF3B30" }
        return String(format: "#%02X%02X%02X",
                      Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()),
                      Int((rgb.blueComponent * 255).rounded()))
    }
}

// MARK: - 键名

enum KeyNaming {

    /// 修饰键符号，按系统显示的固定顺序 ⌃⌥⇧⌘
    static func symbols(flags: UInt64) -> String {
        let value = CGEventFlags(rawValue: flags)
        var text = ""
        if value.contains(.maskControl)   { text += "⌃" }
        if value.contains(.maskAlternate) { text += "⌥" }
        if value.contains(.maskShift)     { text += "⇧" }
        if value.contains(.maskCommand)   { text += "⌘" }
        return text
    }

    /// 由键码 + 修饰键拼出可读文本，例如 "⌃↑"
    static func display(keyCode: UInt16, flags: UInt64) -> String {
        symbols(flags: flags) + keyName(keyCode)
    }

    /// 特殊键（不可打印）单独查表；其余走当前键盘布局反查字符
    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        115: "↖", 116: "⇞", 119: "↘", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20"
    ]

    static func keyName(_ keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        if let character = characterFor(keyCode: keyCode) {
            return character.uppercased()
        }
        return "Key\(keyCode)"
    }

    /// 用当前键盘布局把键码翻成字符（这样非美式布局也能显示对）
    private static func characterFor(keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout,
                                        keyCode,
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }
}

// MARK: - 已安装应用

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleID }
    var name: String
    var path: String
    var bundleID: String
    /// 是「替身文件」解析出来的：路径可能落在别的 app 包内部
    /// （豆包浏览器就在 `Doubao.app/Contents/Helpers/Doubao Browser.app`）。
    /// 这类路径含 `.app/` 是正常的，诊断时不能和"剪枝漏了"混为一谈。
    var viaAlias: Bool = false
}

enum InstalledApps {

    /// 扫描常见目录里的 .app。只取一层子目录 + 两层（含 Utilities 这类子文件夹）。
    ///
    /// 🔴 **见到 `.app` 必须立刻 `skipDescendants()`**。差这一行，枚举器会钻进
    /// 每个应用包内部，把 Contents 里几万个文件全走一遍：本机实测 `/Applications`
    /// 一个根就是 **40.7 万个条目、8.2 秒**，而剪枝后只要 7~14 ms，
    /// 收录结果一个不少（170 个 vs 170 个）。
    /// 以前那版剪枝写成"路径超过两层才剪"，可 `Foo.app` 这一条深度只有 1 层，
    /// 于是永远不剪 —— 这是"每次打开添加应用都要等好几秒"的真正原因。
    static func scan() -> [InstalledApp] {
        let roots = [
            "/Applications",
            "/System/Applications",
            NSHomeDirectory() + "/Applications"
        ]
        var result: [InstalledApp] = []
        var seen = Set<String>()

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else { continue }
            for case let relative as String in enumerator {
                let depth = relative.components(separatedBy: "/").count

                guard relative.hasSuffix(".app") else {
                    // 非 .app 的目录只下探一层（容纳 Utilities / Developer 这类分组目录），
                    // 再深就不要了；普通文件也没有子条目。
                    if depth >= 2 { enumerator.skipDescendants() }
                    continue
                }
                // 见到应用包就往下剪：绝不进包内部
                enumerator.skipDescendants()

                let full = root + "/" + relative
                // 先按普通 bundle 认；认不出来再当「替身 / 软链」解析一次。
                var bundle = Bundle(path: full)
                var path = full
                var aliasName: String?
                if bundle == nil, let real = resolveAlias(URL(fileURLWithPath: full)) {
                    bundle = Bundle(path: real.path)
                    path = real.path
                    // 名字用替身的文件名：那是用户自己认得的那一个
                    aliasName = displayName(of: relative)
                }
                guard let bundle,
                      let bundleID = bundle.bundleIdentifier,
                      !seen.contains(bundleID) else { continue }
                seen.insert(bundleID)
                let name = aliasName
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? displayName(of: relative)
                result.append(InstalledApp(name: name, path: path, bundleID: bundleID,
                                           viaAlias: aliasName != nil))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 「豆包浏览器.app」→「豆包浏览器」
    private static func displayName(of relative: String) -> String {
        (relative as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")
    }

    /// 解析「替身（alias）」或符号链接，返回它指向的真实 .app 目录。
    ///
    /// 有些应用会把本体塞进另一个 app 里——豆包浏览器就在
    /// `Doubao.app/Contents/Helpers/Doubao Browser.app`，用户在「应用程序」里
    /// 只放得下一个 **952 字节的替身文件**，那根本不是目录，
    /// `Bundle(path:)` 直接返回 nil，于是搜索里永远看不到它。
    /// 这里把替身解开，按真实 bundle 收录；作用域存的仍是 bundleID，
    /// 所以运行时按前台应用匹配照样准。
    static func resolveAlias(_ url: URL) -> URL? {
        // ① 老式 alias 文件 / 符号链接
        if let resolved = try? URL(resolvingAliasFileAt: url, options: [.withoutUI]),
           resolved.path != url.path,
           let app = appDirectory(resolved) {
            return app
        }
        // ② bookmark 文件（新版系统拖出来的替身多半是这种）
        if let data = try? Data(contentsOf: url) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [],
                                       relativeTo: nil, bookmarkDataIsStale: &stale),
               resolved.path != url.path,
               let app = appDirectory(resolved) {
                return app
            }
        }
        return nil
    }

    /// 只认「目录型 .app」——替身旁边那些同名的普通文件不能混进来
    private static func appDirectory(_ url: URL) -> URL? {
        guard url.pathExtension == "app" else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    static func icon(forPath path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return icon
    }
}
