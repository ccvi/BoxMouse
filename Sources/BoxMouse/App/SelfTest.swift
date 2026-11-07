import AppKit
import CoreGraphics

// ============================================================
// 自检（发布门禁）
//
// 不依赖 XCTest：本机只有 Command Line Tools。build-app.sh 会在打包前
// 跑 `BoxMouse --selftest`，非 0 退出就不出包。
//
// ⚠️ 空输入就跳过断言 = 假通过。每条断言都要求真实数据参与。
// ============================================================

@MainActor
enum SelfTest {

    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("✓ \(message)")
        } else {
            failures += 1
            print("✗ \(message)")
        }
    }

    static func run() -> Int32 {
        print("BoxMouse 自检")
        print("────────────────────────────────")

        testRecognizer()
        testStraightLineDeadZone()
        testDirectionString()
        testStoreRoundTrip()
        testScopeMatching()
        testTargetActivation()
        testGroupEditing()
        testBackupRestore()
        testMatchingAgainstSeeds()
        testKeyNaming()
        testKindFilter()
        testFeedbackHUDColors()
        testShortcutUsability()
        testShortcutRoundTrip()
        testShortcutMatching()
        testSettingsCompatibility()
        testWindowOps()
        testModifiers()
        testTrackpad()
        testTrackpadModifierMatching()
        testReplayMarkPassthrough()
        testMenuBarIcon()
        testBrowserOps()
        testTrackpadRecognizer()
        testZigzagRecognition()
        testDiagonalAngleTolerance()
        testTriggerDescriptionShowsModifiers()
        testTrackpadPathGesture()
        testTrackpadPathRequiresModifier()
        testTrackpadTrailMapping()
        testTrackpadEngineLifecycle()
        testAppAliasResolution()
        testAppScanPruning()
        testMemoryReclaim()
        testTrackpadAvailability()
        testTrackpadFailureReport()

        print("────────────────────────────────")
        if failures == 0 {
            print("全部通过")
            return 0
        }
        print("\(failures) 项失败")
        return 1
    }

    // MARK: - 识别

    /// 归一化必须保真：等比缩放不压轴，抖动多少就留多少。
    ///
    /// 旧算法用"短轴 <15% 压平"的死区，会把 16° 的真斜线放大成 39°，
    /// 折线识别因此不准（用户报"闪电/Z 形要好几次才识别"）。新算法：
    /// 等比缩放保留真实角度，抖动容忍交给识别层的 DTW + RDP 段角度。
    /// 这里只验证归一化本身保真 —— 竖线抖动小、斜线角度不变、两臂都保留。
    private static func testStraightLineDeadZone() {
        /// 造一条从 (100,50) 出发、竖直走 200px、水平漂移漂移量的轨迹
        func line(driftX: CGFloat) -> [CGPoint] {
            (0...40).map { index in
                let t = CGFloat(index) / 40
                return CGPoint(x: 100 + driftX * t, y: 50 + 200 * t)
            }
        }

        let jittery = PathRecognizer.normalize(line(driftX: 12))   // 6% 漂移
        let maxX = jittery.map { abs($0.x) }.max() ?? 1
        check(maxX < 0.15, "带 6% 抖动的竖线归一化后依然接近垂直（x 幅度 \(String(format: "%.3f", maxX))，不放大）")

        let maxY = jittery.map { abs($0.y) }.max() ?? 0
        check(maxY > 0.9, "压平短轴不会把长轴也压扁（y 幅度 \(String(format: "%.3f", maxY))）")

        // 真斜线的角度必须原样保留：等比缩放下 x/y 幅度比 = 实际比例 0.5
        let diagonal = PathRecognizer.normalize(line(driftX: 100))  // 50% 角
        let diagonalX = diagonal.map { abs($0.x) }.max() ?? 0
        let diagonalY = diagonal.map { abs($0.y) }.max() ?? 1
        check(abs(diagonalX / diagonalY - 0.5) < 0.1,
              "真斜线角度不被改变（x/y 比例 \(String(format: "%.2f", diagonalX / diagonalY))，应约 0.5）")

        // L 形短臂一般是长臂的四到六成，绝不能被当成抖动吃掉
        var lShape: [CGPoint] = []
        for index in 0...20 { lShape.append(CGPoint(x: 120 * CGFloat(index) / 20, y: 0)) }
        for index in 1...20 {
            lShape.append(CGPoint(x: 120, y: 60 * CGFloat(index) / 20))
        }
        let normalizedL = PathRecognizer.normalize(lShape)
        let lX = normalizedL.map { abs($0.x) }.max() ?? 0
        let lY = normalizedL.map { abs($0.y) }.max() ?? 0
        check(lX > 0.5 && lY > 0.5,
              "L 形两臂都保留（x \(String(format: "%.2f", lX)) / y \(String(format: "%.2f", lY))）")

        // 同一条竖线画两遍、抖动方向相反，必须互相命中
        let first = PathRecognizer.normalize(line(driftX: 14))
        let second = PathRecognizer.normalize(line(driftX: -16))
        let score = PathRecognizer.score(first, second)
        check(score >= PathRecognizer.matchThreshold,
              "两次手绘的竖线互相命中（分数 \(String(format: "%.3f", score))）")

        // 显示层修正：直线短轴的手抖被置中（缩略图不再有锯齿），斜线不动。
        // first 是竖线（漂移在 x），短轴是 x。
        let straightened = PathRecognizer.displayStraighten(first)
        let straightenedX = straightened.map { $0.x }.max() ?? 1
        check(straightenedX == straightened.map { $0.x }.min(),
              "显示修正把直线短轴置中（x 幅度 \(String(format: "%.3f", straightenedX))）")
        let diagonalDisplay = PathRecognizer.displayStraighten(diagonal)
        let displayY = diagonalDisplay.map { $0.y }.max() ?? 0
        let displayYMin = diagonalDisplay.map { $0.y }.min() ?? 0
        check(displayY - displayYMin > 0.4,
              "显示修正不会把真斜线压平（y 跨度 \(String(format: "%.2f", displayY - displayYMin))）")
    }

    private static func testRecognizer() {
        let up = (0..<20).map { CGPoint(x: 0, y: Double($0)) }
        let normalizedUp = PathRecognizer.normalize(up)
        check(normalizedUp.count == PathRecognizer.sampleCount,
              "重采样点数 = \(PathRecognizer.sampleCount)")

        // 同一条轨迹与自身必须 1.0
        check(PathRecognizer.score(normalizedUp, normalizedUp) > 0.999,
              "自身匹配分数为 1")

        // 缩放不影响：把同一条线拉长 5 倍
        let longerUp = (0..<20).map { CGPoint(x: 0, y: Double($0) * 5) }
        let scoreScaled = PathRecognizer.score(normalizedUp, PathRecognizer.normalize(longerUp))
        check(scoreScaled > 0.999, "缩放不变（分数 \(String(format: "%.3f", scoreScaled))）")

        // 平移不影响：整体挪 300 像素
        let shiftedUp = up.map { CGPoint(x: $0.x + 300, y: $0.y + 120) }
        let scoreShifted = PathRecognizer.score(normalizedUp, PathRecognizer.normalize(shiftedUp))
        check(scoreShifted > 0.999, "平移不变（分数 \(String(format: "%.3f", scoreShifted))）")

        // 方向必须能区分：向上 vs 向右
        let right = (0..<20).map { CGPoint(x: Double($0), y: 0) }
        let scoreDifferent = PathRecognizer.score(normalizedUp, PathRecognizer.normalize(right))
        check(scoreDifferent < PathRecognizer.matchThreshold,
              "向上与向右不匹配（分数 \(String(format: "%.3f", scoreDifferent)) < 阈值 \(PathRecognizer.matchThreshold)）")

        // 长度计算
        let length = PathRecognizer.length([CGPoint(x: 0, y: 0), CGPoint(x: 3, y: 4)])
        check(abs(length - 5) < 0.001, "轨迹长度 3-4-5 直角 = 5")
    }

    private static func testDirectionString() {
        // 先下后右（屏幕坐标 y 向下，所以 (0,1) 是向下）
        let path = PathRecognizer.normalize([
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)
        ])
        let text = PathRecognizer.directionString(path)
        check(text.contains("↓") && text.contains("→"),
              "方向串包含 ↓ 与 →（实际 \"\(text)\"）")
    }

    // MARK: - 存储

    private static func testStoreRoundTrip() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-selftest-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)

        let before = store.gestures.count
        check(before > 0, "首次启动生成出厂手势（\(before) 条）")

        var gesture = Gesture(name: "自检手势",
                              trigger: .middleButton,
                              action: .keystroke(KeyCombo(keyCode: 126, flags: CGEventFlags.maskCommand.rawValue, display: "⌘↑")),
                              scopeID: store.globalScope.id)
        gesture.path = PathRecognizer.normalize([CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0)])
        store.add(gesture)
        check(store.gestures.count == before + 1, "新增手势后数量 +1")

        // 重新打开：内容必须持久化
        let reopened = GestureStore(directory: temp)
        check(reopened.gestures.contains { $0.name == "自检手势" }, "重新加载后仍能找到新增手势")

        // 删除
        reopened.delete(ids: [gesture.id])
        check(!reopened.gestures.contains { $0.name == "自检手势" }, "删除生效")

        // 批量启停
        let ids = Set(reopened.gestures.map(\.id))
        reopened.setEnabled(false, ids: ids)
        check(reopened.gestures.allSatisfy { !$0.enabled }, "批量禁用全部生效")
        reopened.setEnabled(true, ids: ids)
        check(reopened.gestures.allSatisfy(\.enabled), "批量启用全部生效")

        try? FileManager.default.removeItem(at: temp)
    }

    /// 键盘类动作要不要先把目标应用激活。
    ///
    /// 用户报的：「鼠标已经在 Edge 上，浮层提示对了，但手势没作用，非得点一下浏览器」。
    /// 根因是合成的 ⌘T 一定落在当前前台应用上，跟作用域判成谁无关。
    private static func testTargetActivation() {
        // 指针在 Edge（pid 100）上、前台是终端（pid 200）、命中的是「浏览器」组作用域 → 要激活
        check(TargetResolver.needsActivation(targetPID: 100, frontPID: 200, scopeIsGlobal: false),
              "后台的应用作用域手势会先激活目标应用")

        // 已经在前台就别多此一举（激活等于抢焦点，没必要）
        check(!TargetResolver.needsActivation(targetPID: 100, frontPID: 100, scopeIsGlobal: false),
              "目标应用已在前台时不激活")

        // 全局作用域：指针只是恰好停在桌面/别的窗口上，不该把那个应用拽到前台
        check(!TargetResolver.needsActivation(targetPID: 100, frontPID: 200, scopeIsGlobal: true),
              "全局作用域手势不激活（仍打给前台应用）")

        // 解析不出目标进程时什么也做不了，别激活
        check(!TargetResolver.needsActivation(targetPID: nil, frontPID: 200, scopeIsGlobal: false),
              "没有目标进程时不激活")
        // 拿不到前台进程（极少见）：保守地照激活做——宁可把目标应用带到前台，
        // 也别把一个 ⌘W 打给"不知道是谁"的应用
        check(TargetResolver.needsActivation(targetPID: 100, frontPID: nil, scopeIsGlobal: false),
              "前台进程未知时保守激活")

        // 指针底下那个元素的 pid 拿不到窗口时，解析结果不能崩：这条走的是防御分支
        let empty = TargetContext()
        check(!empty.activatesTarget, "默认上下文不激活（快捷键那条路走它）")
    }

    private static func testScopeMatching() {
        let global = ScopeEntry.global()
        check(global.covers(bundleID: "com.apple.Safari"), "全局作用域覆盖任意应用")
        check(global.covers(bundleID: nil), "全局作用域覆盖无 bundle id 的情况")

        let app = ScopeEntry.app(name: "Safari", bundleID: "com.apple.Safari")
        check(app.covers(bundleID: "com.apple.Safari"), "应用作用域命中自己")
        check(!app.covers(bundleID: "com.apple.Terminal"), "应用作用域不误伤别的应用")

        let group = ScopeEntry.group(name: "浏览器", bundleIDs: ["com.apple.Safari", "com.google.Chrome"])
        check(group.covers(bundleID: "com.google.Chrome"), "应用组命中组内成员")
        check(!group.covers(bundleID: "com.apple.Terminal"), "应用组不命中组外应用")
    }

    private static func testGroupEditing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-group-\(UUID().uuidString)")
        let store = GestureStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let group = store.addGroupScope(name: "浏览器", bundleIDs: ["com.apple.Safari"])
        check(store.scope(id: group.id)?.bundleIDs == ["com.apple.Safari"], "新建组只有一个成员")

        // 加成员：以前这条路根本不存在，组建成后成员就定死了
        let added = store.updateGroupScope(id: group.id,
                                           name: "浏览器",
                                           bundleIDs: ["com.apple.Safari", "com.google.Chrome"])
        let afterAdd = store.scope(id: group.id)?.bundleIDs ?? []
        check(added && afterAdd.count == 2, "能给已有组加成员（实际 \(afterAdd.count) 个）")

        // 减成员
        store.updateGroupScope(id: group.id, name: "浏览器", bundleIDs: ["com.google.Chrome"])
        check(store.scope(id: group.id)?.bundleIDs == ["com.google.Chrome"], "能把成员移出组")

        // 改名
        store.updateGroupScope(id: group.id, name: "上网的", bundleIDs: ["com.google.Chrome"])
        check(store.scope(id: group.id)?.name == "上网的", "能给组改名")

        // 组名不该被空白清空
        store.updateGroupScope(id: group.id, name: "   ", bundleIDs: ["com.google.Chrome"])
        check(store.scope(id: group.id)?.name == "上网的", "组名传空白时保留原名，不会被清空")

        // 落盘往返：改完得能读回来，否则重启就回滚了
        let reloaded = GestureStore(directory: dir)
        let persisted = reloaded.scope(id: group.id)
        check(persisted?.name == "上网的" && persisted?.bundleIDs == ["com.google.Chrome"],
              "改组成员后能持久化（读回 \(persisted?.name ?? "nil") / \(persisted?.bundleIDs.count ?? -1) 个）")

        // 单个应用作用域不能被这种接口改写：改 bundle id 等于换了个应用
        let app = store.addAppScope(name: "Terminal", bundleID: "com.apple.Terminal")
        let touched = store.updateGroupScope(id: app.id, name: "x", bundleIDs: ["someone.else"])
        check(!touched, "单个应用作用域不接受组编辑")
        check(store.scope(id: app.id)?.bundleIDs == ["com.apple.Terminal"], "应用作用域没被改坏")
    }

    /// 备份 / 恢复：重点是"整体替换"而不是"合并叠加"，
    /// 以及 v1 旧备份（没有 settings）恢复时不能把本机设置冲掉。
    private static func testBackupRestore() {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-backup-\(UUID().uuidString)")
        let store = GestureStore(directory: source)
        let originalCount = store.gestures.count
        let originalScopes = store.scopes.count
        store.settings.minPathLength = 27
        store.settings.showTrail = false
        store.flushSettings()

        guard let data = try? store.backupData() else {
            check(false, "备份数据生成失败")
            return
        }
        check(data.count > 100, "备份数据非空（\(data.count) 字节）")

        // 备份里必须真的带上设置，否则"备份了设置"就是句空话
        let text = String(data: data, encoding: .utf8) ?? ""
        check(text.contains("\"settings\""), "备份文件里含 settings 段")
        check(text.contains("\"formatVersion\" : 2"), "备份文件格式版本为 2")

        // 目标机器上先弄脏：多一条手势、设置也是别的值
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-backup-\(UUID().uuidString)")
        let other = GestureStore(directory: target)
        other.settings.minPathLength = 5
        other.settings.showTrail = true
        other.flushSettings()
        let dirtyCount = other.gestures.count + 3
        for offset in 0..<3 {
            let extra = Gesture(name: "脏数据\(offset)",
                                trigger: .rightButton,
                                action: .window(.minimize),
                                scopeID: other.globalScope.id,
                                path: other.gestures.first?.path ?? [])
            other.add(extra)
        }
        check(other.gestures.count == dirtyCount, "恢复前目标库被弄脏（\(other.gestures.count) 条）")

        guard let preview = try? other.previewRestore(data) else {
            check(false, "恢复预览解析失败")
            return
        }
        check(preview.gestureCount == originalCount, "预览手势数 = 备份里的 \(originalCount) 条")
        check(preview.scopeCount == originalScopes, "预览作用域数 = \(originalScopes) 个")
        check(preview.hasSettings, "预览能看出备份含设置")

        if let report = try? other.restore(from: data) {
            check(report.gestures == originalCount, "恢复后手势数 = 备份的 \(originalCount)（替换，不是叠加）")
            check(other.gestures.count == originalCount,
                  "目标库里脏数据被清掉（现有 \(other.gestures.count) 条）")
            check(report.settingsRestored, "恢复报告标明设置已恢复")
            check(other.settings.minPathLength == 27, "设置恢复成备份里的 27（现在 \(other.settings.minPathLength)）")
            check(other.settings.showTrail == false, "开关状态也恢复了（showTrail = \(other.settings.showTrail)）")
            check(report.snapshotName != nil, "覆盖前留了快照：\(report.snapshotName ?? "无")")
            if let name = report.snapshotName {
                let url = other.configDirectory.appendingPathComponent(name)
                check(FileManager.default.fileExists(atPath: url.path), "快照文件真的落到配置文件夹")
            }
        } else {
            check(false, "恢复抛错")
        }

        // 恢复两次不该翻倍：这是"替换"和"导入"最本质的区别
        _ = try? other.restore(from: data)
        check(other.gestures.count == originalCount, "连续恢复两次条数不变（\(other.gestures.count)）")

        // v1 旧备份：没有 settings 字段，恢复后本机设置必须原样保留
        let v1 = """
        {"formatVersion":1,"exportedAt":"2026-01-01T00:00:00Z","app":"BoxMouse",
         "gestures":[],"scopes":[{"id":"\(UUID().uuidString)","kind":"global","name":"全局","bundleIDs":[]}]}
        """
        if let v1Data = v1.data(using: .utf8) {
            other.settings.minPathLength = 12
            if let report = try? other.restore(from: v1Data) {
                check(!report.settingsRestored, "v1 备份报告标明不含设置")
                check(other.settings.minPathLength == 12,
                      "v1 备份不清空本机设置（仍是 \(other.settings.minPathLength)）")
                check(other.scopes.contains { $0.kind == .global }, "v1 恢复后仍有全局作用域")
            } else {
                check(false, "v1 旧备份恢复失败")
            }
        }

        // 不是备份的文件要给出可读原因，而不是抛个未处理的解码错误
        let garbage = Data("{\"hello\":1}".utf8)
        do {
            _ = try other.restore(from: garbage)
            check(false, "垃圾文件竟然恢复成功了")
        } catch {
            check(error.localizedDescription.contains("不是有效的"),
                  "垃圾文件的报错可读：\(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: source)
        try? FileManager.default.removeItem(at: target)
    }

    // MARK: - 端到端匹配

    /// 把出厂手势的模板当成"手绘轨迹"再喂回识别器（带抖动），必须命中自己。
    /// 这条最能说明问题：分数算法本身对不代表"用户真画出来也能认出来"。
    private static func testMatchingAgainstSeeds() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-match-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)
        let seeds = store.gestures
        check(!seeds.isEmpty, "出厂手势里有可画的手势（\(seeds.count) 条）")

        for (index, gesture) in seeds.enumerated() {
            // 模板 → 模拟屏幕坐标（放大 220 倍并平移），再加确定性抖动
            let noisy = gesture.path.enumerated().map { offset, point -> CGPoint in
                let jitterX = sin(Double(offset) * 1.7 + Double(index)) * 4
                let jitterY = cos(Double(offset) * 2.3 + Double(index)) * 4
                return CGPoint(x: point.x * 220 + 640 + jitterX,
                               y: point.y * 220 + 400 + jitterY)
            }
            let normalized = PathRecognizer.normalize(noisy)
            let candidates = store.candidates(trigger: gesture.trigger,
                                          modifiers: gesture.modifiers,
                                          bundleID: "com.apple.Safari")
                .filter { !$0.path.isEmpty }
                .map { (gesture: $0, path: $0.path) }
            let match = PathRecognizer.bestMatch(path: normalized, candidates: candidates)
            let hit = match?.gesture.id == gesture.id
            let scoreText = match.map { String(format: "%.2f", $0.score) } ?? "nil"
            check(hit, "重画「\(gesture.name)」命中自己（分数 \(scoreText)）")
        }

        // 反例：一条和任何模板都不像的抖动折线，不该被认成任何手势
        var random = [CGPoint]()
        for step in 0..<24 {
            let t = Double(step) / 24
            random.append(CGPoint(x: 500 + sin(t * 9) * 90, y: 400 + cos(t * 7) * 60))
        }
        let candidates = store.candidates(trigger: .rightButton, bundleID: "com.apple.Safari")
            .filter { !$0.path.isEmpty }
            .map { (gesture: $0, path: $0.path) }
        let stray = PathRecognizer.bestMatch(path: PathRecognizer.normalize(random), candidates: candidates)
        check(stray == nil, "乱画一条曲线不命中任何手势（最高分 \(stray.map { String(format: "%.2f", $0.score) } ?? "nil")）")

        try? FileManager.default.removeItem(at: temp)
    }

    private static func testKeyNaming() {
        let display = KeyNaming.display(keyCode: 126, flags: CGEventFlags.maskControl.rawValue)
        check(display == "⌃↑", "⌃ + 上箭头显示为 ⌃↑（实际 \(display)）")

        let combo = KeyCombo(keyCode: 13, flags: CGEventFlags.maskCommand.rawValue, display: "⌘W")
        check(combo.display == "⌘W", "键位组合显示正确")

        let action = GestureAction.keystroke(combo)
        check(action.summary == "快捷键：⌘W", "动作摘要文本正确（实际 \(action.summary)）")
        check(action.isValid, "完整动作通过校验")

        let empty = GestureAction(kind: .openURL)
        check(!empty.isValid, "缺 URL 的动作不通过校验")
    }

    // MARK: - 列表筛选

    /// 筛选四档必须真能分开三类手势。
    ///
    /// 早先是按鼠标键筛（右键 / 中键 / 侧键绘制），触摸板手势和快捷键永远筛不出来。
    /// 断言盯的是"档位覆盖性"：漏掉任何一种 kind，就会出现"这一类怎么筛都是空的"。
    private static func testKindFilter() {
        check(GestureKindFilter.allCases.count == 4,
              "筛选共四档（实际 \(GestureKindFilter.allCases.count)）")
        check(GestureKindFilter.all.kind == nil, "「全部」不做筛选")

        let kinds = GestureKindFilter.allCases.compactMap(\.kind)
        check(kinds.count == 3, "三个具体档位各对应一种 kind（实际 \(kinds.count) 个）")
        check(Set(kinds) == Set([GestureKind.mouse, .trackpad, .shortcut]),
              "三个档位正好覆盖鼠标 / 触摸板 / 快捷键，不漏也不重")

        let titles = GestureKindFilter.allCases.map(\.title)
        check(Set(titles).count == titles.count, "四档标题互不重复（\(titles.joined(separator: " / "))）")
        check(titles == ["全部", "鼠标手势", "触摸板手势", "快捷键"],
              "档位顺序是 全部 → 鼠标 → 触摸板 → 快捷键（实际 \(titles.joined(separator: " / "))）")
    }

    // MARK: - 提示浮窗配色
    /// 提示胶囊：底色深、文字浅，而且**换到浅色系统外观下也得照样亮**。
    ///
    /// 这条是用户实测报了 bug 之后补的：文字原来用 `.labelColor`，那是随外观翻转的动态色，
    /// 浅色外观下解析成近黑（实测 0,0,0），压在写死的深色胶囊上，"左半屏"三个字完全看不见。
    /// 所以断言不能只看"当前亮度"——必须在 aqua 下解析一遍，那才是出事的现场。
    private static func testFeedbackHUDColors() {
        let bg = FeedbackHUD.capsuleBackground
        let fg = FeedbackHUD.capsuleTextColor
        let secondary = FeedbackHUD.capsuleSecondaryTextColor

        /// 在指定外观下解析出的相对亮度（动态色会随外观变，固定色不变）
        func luminance(_ color: NSColor, in appearance: NSAppearance.Name) -> CGFloat? {
            var value: CGFloat?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                value = FeedbackHUD.relativeBrightness(color)
            }
            return value
        }

        check(bg.type == .componentBased, "胶囊底色是固定色（不是动态色）")
        check(fg.type == .componentBased, "主文字是固定色（不是动态色）")
        check(secondary.type == .componentBased, "次要文字是固定色（不是动态色）")

        guard let bgAqua = luminance(bg, in: .aqua),
              let fgAqua = luminance(fg, in: .aqua),
              let secAqua = luminance(secondary, in: .aqua),
              let fgDark = luminance(fg, in: .darkAqua) else {
            check(false, "拿不到 Aqua / DarkAqua 外观，配色断言无法验证")
            return
        }

        // 关键一条：浅色系统外观下（用户当前就是），文字必须依然亮
        check(fgAqua > 0.9, "浅色外观下主文字也够亮（亮度 \(String(format: "%.2f", fgAqua))）")
        check(secAqua > 0.7, "浅色外观下次要文字也够亮（亮度 \(String(format: "%.2f", secAqua))）")
        check(bgAqua < 0.25, "胶囊底色够深（亮度 \(String(format: "%.2f", bgAqua))）")
        check(fgAqua - bgAqua > 0.7,
              "浅色外观下文字与底色亮度差够大（差 \(String(format: "%.2f", fgAqua - bgAqua))）")
        check(abs(fgAqua - fgDark) < 0.01, "文字色在两种外观下一致（不会翻转）")

        // 对照：动态色确实会翻转成近黑——这条不通过说明上面的判据本身没有区分力
        if let labelAqua = luminance(.labelColor, in: .aqua),
           let labelDark = luminance(.labelColor, in: .darkAqua) {
            check(labelAqua < 0.2 && labelDark > 0.8,
                  "对照：.labelColor 在浅色外观下变黑（\(String(format: "%.2f", labelAqua))）、深色下变白（\(String(format: "%.2f", labelDark))）")
        } else {
            check(false, "对照色解析失败")
        }
    }

    // MARK: - 全局快捷键
    /// 什么键能当快捷键、什么键绝对不能。
    ///
    /// 这条不是洁癖：裸键（没有修饰键的字符键）一旦注册成全局快捷键，
    /// 全系统这个键就归我们了，用户打字直接废掉，而且很难联想到是这个设置干的。
    private static func testShortcutUsability() {
        let cmdK = KeyCombo(keyCode: 40, flags: CGEventFlags.maskCommand.rawValue, display: "⌘K")
        check(cmdK.isUsableAsShortcut, "单修饰键组合可用（⌘K）")
        check(cmdK.shortcutModifierCount == 1, "⌘K 数出 1 个修饰键")

        // 用户口径：修饰键**要能**同时按两个（⌘⇧K 这类常用），但最多两个。
        // 这条限制拦在可用性判定里，录制器只是提前拦一道。
        let cmdShiftK = KeyCombo(keyCode: 40,
                                 flags: (CGEventFlags.maskCommand.rawValue
                                         | CGEventFlags.maskShift.rawValue),
                                 display: "⇧⌘K")
        check(cmdShiftK.isUsableAsShortcut, "两个修饰键可用（⇧⌘K）")
        check(cmdShiftK.shortcutModifierCount == 2, "⇧⌘K 数出 2 个修饰键")

        let three = KeyCombo(keyCode: 40,
                             flags: (CGEventFlags.maskCommand.rawValue
                                     | CGEventFlags.maskShift.rawValue
                                     | CGEventFlags.maskAlternate.rawValue),
                             display: "⌥⇧⌘K")
        check(!three.isUsableAsShortcut, "三个修饰键被拒（上限定为两个）")
        check(three.shortcutModifierCount == 3, "三修饰键数出 3 个")

        let bareA = KeyCombo(keyCode: 0, flags: 0, display: "A")
        check(!bareA.isUsableAsShortcut, "裸字母不能当全局快捷键")

        // 单独一个 F 键没有输入含义，可以放心用
        let bareF5 = KeyCombo(keyCode: 96, flags: 0, display: "F5")
        check(bareF5.isUsableAsShortcut, "功能键可以单独使用（F5，键码 96 在功能键表里）")
        check(bareF5.shortcutModifierCount == 0, "裸功能键的修饰键个数为 0")

        // 功能键 + 一个修饰键 = 允许；功能键 + 两个修饰键 = 拒绝
        let ctrlF5 = KeyCombo(keyCode: 96, flags: CGEventFlags.maskControl.rawValue, display: "⌃F5")
        check(ctrlF5.isUsableAsShortcut, "功能键配一个修饰键可用（⌃F5）")

        // Fn 不算：不同键盘上报不一致，算进匹配范围会让快捷键时灵时不灵
        let fnOnly = KeyCombo(keyCode: 40, flags: CGEventFlags.maskSecondaryFn.rawValue, display: "K")
        check(!fnOnly.isUsableAsShortcut, "只按 Fn 不算修饰键，裸键依旧被拒")
        check(fnOnly.shortcutModifierCount == 0, "Fn 不计入修饰键个数")

        // 空格是字符键，不在功能键表里
        let space = KeyCombo(keyCode: 49, flags: 0, display: "Space")
        check(!space.isUsableAsShortcut, "裸空格被拒（键码 49 不算功能键）")
    }

    /// 快捷键的编解码：老配置没有 hotkey 字段，不能因此整份读不出来。
    private static func testShortcutRoundTrip() {
        let hotkey = KeyCombo(keyCode: 40,
                              flags: CGEventFlags.maskCommand.rawValue,
                              display: "⌘K")
        var gesture = Gesture.shortcut(name: "静音一下", hotkey: hotkey,
                                       action: .media(.mute), scopeID: UUID())
        check(gesture.kind == .shortcut, "工厂方法产出 .shortcut 类型")
        check(gesture.triggerDescription == "⌘K", "列表「触发方式」列直接显示按键（实际 \(gesture.triggerDescription)）")

        let encoder = JSONEncoder()
        if let data = try? encoder.encode(gesture),
           let decoded = try? JSONDecoder().decode(Gesture.self, from: data) {
            check(decoded.hotkey == hotkey, "快捷键编解码往返一致")
            check(decoded.kind == .shortcut, "解码后仍是 .shortcut")
        } else {
            check(false, "快捷键编解码失败")
        }

        // 老版本存下来的鼠标手势条目里没有 hotkey 键
        gesture.hotkey = nil
        check(gesture.triggerDescription == "未设置快捷键", "缺按键时给出可读占位而不是空字符串")

        let legacy = """
        {"id":"\(UUID().uuidString)","name":"老条目","kind":"mouse",
         "trigger":"rightButton","modifiers":[],"enabled":true,"path":[],
         "action":{"kind":"window","windowOp":"minimize"},
         "scopeID":"\(UUID().uuidString)"}
        """
        if let data = legacy.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Gesture.self, from: data) {
            check(decoded.hotkey == nil, "旧配置缺 hotkey 字段仍可解码")
        } else {
            check(false, "旧配置缺 hotkey 字段导致解码失败")
        }
    }

    /// 匹配：键码 + 修饰键全等、应用作用域优先于全局、停用的条目不参与。
    private static func testShortcutMatching() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-shortcut-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)
        store.delete(ids: Set(store.gestures.map(\.id)))

        let combo = KeyCombo(keyCode: 40,
                             flags: CGEventFlags.maskCommand.rawValue,
                             display: "⌘K")
        let flags = CGEventFlags(rawValue: combo.flags)

        let global = Gesture.shortcut(name: "全局静音", hotkey: combo,
                                      action: .media(.mute), scopeID: store.globalScope.id)
        store.add(global)

        let safari = store.addAppScope(name: "Safari", bundleID: "com.apple.Safari")
        let scoped = Gesture.shortcut(name: "Safari 专用", hotkey: combo,
                                      action: .window(.leftHalf), scopeID: safari.id)
        store.add(scoped)

        // 同键不同修饰键，不该串。用单修饰键做用例：双修饰键现在整体被判定为不可用。
        let other = Gesture.shortcut(name: "⌥K",
                                     hotkey: KeyCombo(keyCode: 40,
                                                      flags: CGEventFlags.maskAlternate.rawValue,
                                                      display: "⌥K"),
                                     action: .window(.maximize), scopeID: store.globalScope.id)
        store.add(other)

        let hitGlobal = store.shortcutMatch(keyCode: 40, flags: flags, bundleID: "com.apple.Terminal")
        check(hitGlobal?.id == global.id, "无专属作用域时命中全局快捷键")

        let hitScoped = store.shortcutMatch(keyCode: 40, flags: flags, bundleID: "com.apple.Safari")
        check(hitScoped?.id == scoped.id, "应用作用域优先于全局（同一按键）")

        let hitAlt = store.shortcutMatch(keyCode: 40,
                                         flags: .maskAlternate,
                                         bundleID: "com.apple.Terminal")
        check(hitAlt?.id == other.id, "修饰键不同不串（⌥K 命中自己，不会被 ⌘K 抢走）")

        // 两修饰键也要能正常命中（用户明确要求支持），且不能和单修饰键串
        let cmdShiftK = Gesture.shortcut(
            name: "⇧⌘K",
            hotkey: KeyCombo(keyCode: 40,
                             flags: (CGEventFlags.maskCommand.rawValue
                                     | CGEventFlags.maskShift.rawValue),
                             display: "⇧⌘K"),
            action: .window(.leftHalf), scopeID: store.globalScope.id)
        store.add(cmdShiftK)
        let hitTwo = store.shortcutMatch(keyCode: 40,
                                         flags: flags.union(.maskShift),
                                         bundleID: "com.apple.Terminal")
        check(hitTwo?.id == cmdShiftK.id, "两修饰键条目能命中（⇧⌘K）")

        // 绕过编辑器写进来的三修饰键条目：不参与匹配，等于失效但不会误触发别人的键
        let overLimit = Gesture.shortcut(
            name: "超限的三修饰键",
            hotkey: KeyCombo(keyCode: 40,
                             flags: (CGEventFlags.maskCommand.rawValue
                                     | CGEventFlags.maskShift.rawValue
                                     | CGEventFlags.maskAlternate.rawValue),
                             display: "⌥⇧⌘K"),
            action: .window(.rightHalf), scopeID: store.globalScope.id)
        store.add(overLimit)
        let overHit = store.shortcutMatch(keyCode: 40,
                                          flags: flags.union(.maskShift).union(.maskAlternate),
                                          bundleID: "com.apple.Terminal")
        check(overHit?.id != overLimit.id, "三个修饰键的条目不会被执行")

        let miss = store.shortcutMatch(keyCode: 41, flags: flags, bundleID: "com.apple.Terminal")
        check(miss == nil, "键码不同不命中")

        // 大小写/设备相关位不能影响匹配
        let noisy = store.shortcutMatch(keyCode: 40,
                                        flags: flags.union(.maskAlphaShift).union(.maskNumericPad),
                                        bundleID: "com.apple.Terminal")
        check(noisy?.id == global.id, "CapsLock 之类的标志位不参与匹配")

        store.setEnabled(false, ids: [global.id])
        let afterDisable = store.shortcutMatch(keyCode: 40, flags: flags, bundleID: "com.apple.Terminal")
        check(afterDisable == nil, "停用的快捷键不参与匹配")

        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - 设置兼容 & 菜单栏

    /// 老版本 settings.json 里没有后加的键。合成解码器会抛 keyNotFound，
    /// 外层 try? 再把整份配置丢掉——升级一次等于配置清空。
    /// 这条断言就是拦这个的，用真实老结构喂养，不是手搓理想 JSON。
    private static func testSettingsCompatibility() {
        let legacy = """
        {
          "engineEnabled": false,
          "minPathLength": 30,
          "trailColorHex": "#00A0FF",
          "showTrail": false
        }
        """
        guard let decoded = try? JSONDecoder().decode(BoxMouseSettings.self, from: Data(legacy.utf8)) else {
            check(false, "旧版设置文件（缺新字段）仍可解码")
            return
        }
        check(decoded.engineEnabled == false, "旧配置里写过的值保留（engineEnabled = false）")
        check(decoded.minPathLength == 30, "旧配置数值保留（minPathLength = 30）")
        check(decoded.showTrail == false, "旧配置布尔保留（showTrail = false）")
        check(decoded.hideDockIcon == BoxMouseSettings().hideDockIcon,
              "缺失的新字段回落到默认值（hideDockIcon = \(decoded.hideDockIcon)）")

        // 回写再读一遍：保证新增字段真的进了文件，而不是每次都被默认值盖掉
        var settings = decoded
        settings.hideDockIcon = true
        guard let data = try? JSONEncoder().encode(settings),
              let redecoded = try? JSONDecoder().decode(BoxMouseSettings.self, from: data) else {
            check(false, "设置编码后可再次解码")
            return
        }
        check(redecoded.hideDockIcon, "隐藏 Dock 图标开关能持久化")
        check(redecoded == settings, "设置往返后完全一致")
    }

    private static func testWindowOps() {
        // 手势场景不能给"切换"式动作：画同一个手势时窗口状态不可知，结果不可预测。
        // 所以最大化与还原必须各自是独立动作，且语义不能重合。
        check(WindowOp.maximize != WindowOp.restore, "最大化与还原是两个独立动作")
        check(WindowOp.maximize.displayName != WindowOp.restore.displayName,
              "两者的显示名不同（\(WindowOp.maximize.displayName) / \(WindowOp.restore.displayName)）")
        check(WindowOp.allCases.count == 16, "窗口操作共 16 个（实际 \(WindowOp.allCases.count)）")

        // 平铺/居中的几何。真机上只能靠肉眼看窗口摆得对不对，
        // 而"差半像素发虚""右半屏留 1pt 缝"这种事肉眼当场分不出来，只能钉死算例。
        // 基准：可用区 1710×1082（已扣菜单栏），主屏高 1107 → AX 的 y = 1107-1082+偏移 = 25+偏移
        let visible = CGRect(x: 0, y: 0, width: 1710, height: 1082)
        let flip: CGFloat = 1107

        check(ActionRunner.tileFrame(.leftHalf, in: visible, flipBase: flip)
                == CGRect(x: 0, y: 25, width: 855, height: 1082),
              "左半屏：贴左、占一半宽、满高")
        check(ActionRunner.tileFrame(.rightHalf, in: visible, flipBase: flip)
                == CGRect(x: 855, y: 25, width: 855, height: 1082),
              "右半屏：从中间起、紧接左半屏")
        // 居中的两个动作只缩宽度、上下满高（用户口径："宽度占 2/3 屏，上下满屏"）。
        // 早先实现成宽高同比缩放，那是"小一号的窗口"，不是要的东西。
        check(ActionRunner.tileFrame(.centerTwoThirds, in: visible, flipBase: flip)
                == CGRect(x: 285, y: 25, width: 1140, height: 1082),
              "居中 2/3：宽度占 2/3、左右各留 285、上下满高")
        check(ActionRunner.tileFrame(.centerThreeFourths, in: visible, flipBase: flip)
                == CGRect(x: 214, y: 25, width: 1282, height: 1082),
              "居中 3/4：宽度占 3/4、左右各留 214、上下满高")
        check(ActionRunner.tileFrame(.leftThreeFifths, in: visible, flipBase: flip)
                == CGRect(x: 0, y: 25, width: 1026, height: 1082),
              "左 3/5：宽度占 3/5（1710×0.6=1026），贴左边、上下满高")
        // 3/5 是插在半屏和 2/3 之间的中间档。比例写错（比如误写成 3/4）
        // 光看单条断言不容易发现，用大小关系再钉一道。
        if let halfWidth = ActionRunner.tileFrame(.leftHalf, in: visible, flipBase: flip)?.width,
           let threeFifths = ActionRunner.tileFrame(.leftThreeFifths, in: visible, flipBase: flip)?.width,
           let twoThirds = ActionRunner.tileFrame(.leftTwoThirds, in: visible, flipBase: flip)?.width {
            check(halfWidth < threeFifths && threeFifths < twoThirds,
                  "左 3/5 的宽度落在左半屏（\(Int(halfWidth))）与左 2/3（\(Int(twoThirds))）之间，实际 \(Int(threeFifths))")
        } else {
            check(false, "左 3/5 的宽度落在左半屏与左 2/3 之间")
        }
        check(ActionRunner.tileFrame(.leftTwoThirds, in: visible, flipBase: flip)
                == CGRect(x: 0, y: 25, width: 1140, height: 1082),
              "左 2/3：与居中 2/3 同宽同高，贴左边")
        // 右侧三个动作：宽度只按比例算一次，位置用「右边界减宽度」，
        // 所以左 2/3 与右 2/3 一定同宽，右边缘一定贴齐可用区右边。
        check(ActionRunner.tileFrame(.rightTwoThirds, in: visible, flipBase: flip)
                == CGRect(x: 570, y: 25, width: 1140, height: 1082),
              "右 2/3：与左 2/3 同宽，贴右边（右边缘 1710）")
        check(ActionRunner.tileFrame(.leftThreeFourths, in: visible, flipBase: flip)
                == CGRect(x: 0, y: 25, width: 1282, height: 1082),
              "左 3/4：宽度占 3/4（1710×0.75=1282 向下取整），贴左边")
        check(ActionRunner.tileFrame(.rightThreeFourths, in: visible, flipBase: flip)
                == CGRect(x: 428, y: 25, width: 1282, height: 1082),
              "右 3/4：与左 3/4 同宽，贴右边")
        for (leftOp, rightOp) in [(WindowOp.leftTwoThirds, WindowOp.rightTwoThirds),
                                  (.leftThreeFourths, .rightThreeFourths)] {
            let l = ActionRunner.tileFrame(leftOp, in: visible, flipBase: flip)
            let r = ActionRunner.tileFrame(rightOp, in: visible, flipBase: flip)
            check(l?.width == r?.width, "\(leftOp.displayName) 与 \(rightOp.displayName) 同宽")
            check(r?.maxX == visible.maxX, "\(rightOp.displayName) 右边缘贴齐可用区，不留缝")
            check(l?.minX == visible.minX, "\(leftOp.displayName) 左边缘贴齐可用区")
            check(l?.height == visible.height && r?.height == visible.height,
                  "\(leftOp.displayName) / \(rightOp.displayName) 上下满高")
        }
        check(ActionRunner.tileFrame(.topLeftQuarter, in: visible, flipBase: flip)
                == CGRect(x: 0, y: 25, width: 855, height: 541),
              "左上 1/4：宽高各占一半，贴左上角")

        // 满屏 = 可用区整块。注意它和「切换全屏」是两回事：全屏会把窗口塞进独立空间，
        // 满屏只是把 frame 设成可用区那么大，菜单栏和 Dock 都留在外面。
        check(ActionRunner.tileFrame(.fillScreen, in: visible, flipBase: flip)
                == CGRect(x: 0, y: 25, width: 1710, height: 1082),
              "满屏：正好等于可用区（扣掉菜单栏与 Dock）")
        check(ActionRunner.tileFrame(.fillScreen, in: visible, flipBase: flip)?.height
                == visible.height,
              "满屏高度取可用区高度，不是屏幕高度")
        check(WindowOp.fillScreen.isTiling && WindowOp.fillScreen != .fullScreen,
              "满屏属于平铺类，且与切换全屏是两个动作")
        check(WindowOp.fillScreen.displayName != WindowOp.fullScreen.displayName,
              "满屏与全屏显示名不同（\(WindowOp.fillScreen.displayName) / \(WindowOp.fullScreen.displayName)）")

        // 宽度是奇数时，左右两半加起来必须正好等于屏宽：不能重叠，也不能留缝
        let odd = CGRect(x: 0, y: 0, width: 1711, height: 1000)
        let leftOdd = ActionRunner.tileFrame(.leftHalf, in: odd, flipBase: 1000)
        let rightOdd = ActionRunner.tileFrame(.rightHalf, in: odd, flipBase: 1000)
        check(leftOdd?.width == 855 && rightOdd?.width == 856,
              "奇数宽度下左半 855 + 右半 856 = 1711，不留缝不重叠")
        check(leftOdd?.maxX == rightOdd?.minX, "左右半屏在中间严丝合缝")

        // 不是平铺类的动作不能被这套几何逻辑误接
        check(ActionRunner.tileFrame(.maximize, in: visible, flipBase: flip) == nil,
              "最大化不经平铺逻辑")
        check(!WindowOp.maximize.isTiling && WindowOp.leftHalf.isTiling,
              "isTiling 只对平铺/居中为真")

        // 副屏在主屏上方时（NS 坐标 minY=1200），算出来的 AX y 是负的 —— 这是对的，
        // AX 坐标允许负值，表示"在主屏顶边之上"。写死成非负会让窗口跑到主屏去。
        let above = CGRect(x: 0, y: 1200, width: 1710, height: 1082)
        check(ActionRunner.tileFrame(.leftHalf, in: above, flipBase: 1107)?.minY == -1175,
              "副屏在上方时 y 为负，不会落到主屏")

        // 老配置里的「最大化 / 还原」（zoom）要能继续读进来，不能被当成未知值
        // ——那会让整条手势在解码时失败，用户升级后动作凭空消失。
        let legacy = (try? JSONDecoder().decode(WindowOp.self, from: Data("\"zoom\"".utf8)))
        check(legacy == .maximize, "老配置的 zoom 迁移为「最大化窗口」")

        // 反过来，真正的未知值必须报错，而不是静默落到某个默认动作上
        let unknown = (try? JSONDecoder().decode(WindowOp.self, from: Data("\"fly\"".utf8))) != nil
        check(!unknown, "未知的窗口操作解码失败，不会静默顶替")

        // 「还原」到底动哪个窗口。
        // 用户报的：最小化浏览器 → 焦点跳到 Finder → 再还原，出来的是文件夹。
        // 根因是"当前应用的最小化窗口"排在"上一次最小化的那个"前面。
        check(ActionRunner.restorePlan(startWindowExists: true, startMinimized: true,
                                      startFillingScreen: false, hasRemembered: true,
                                      hasCurrentAppMinimized: true) == .startWindow,
              "起手那个窗口就在 Dock 里时，直接还原它")
        check(ActionRunner.restorePlan(startWindowExists: true, startMinimized: false,
                                      startFillingScreen: true, hasRemembered: true,
                                      hasCurrentAppMinimized: true) == .cancelZoom,
              "起手窗口是最大化的，还原 = 取消缩放，不能被记忆抢走")
        check(ActionRunner.restorePlan(startWindowExists: true, startMinimized: false,
                                      startFillingScreen: false, hasRemembered: true,
                                      hasCurrentAppMinimized: true) == .remembered,
              "焦点已经换到别的应用（Finder）时，仍要还原刚最小化的那个窗口")
        check(ActionRunner.restorePlan(startWindowExists: true, startMinimized: false,
                                      startFillingScreen: false, hasRemembered: false,
                                      hasCurrentAppMinimized: true) == .currentApp,
              "没有记忆时才退回当前应用自己的最小化窗口")
        check(ActionRunner.restorePlan(startWindowExists: true, startMinimized: false,
                                      startFillingScreen: false, hasRemembered: false,
                                      hasCurrentAppMinimized: false) == .nothing,
              "什么都没最小化时，还原不做任何事")

        // 最小化记忆必须是栈：连着最小化 3 个应用，要能一个个还原回来。
        // 只记最后一次的时候，还原掉一个就空了（用户报："最小化了 3 个应用，最后还原的只有一个"）。
        let now = Date()
        var memory = MinimizeMemory<Int>()
        memory.push(1, at: now.addingTimeInterval(-30))
        memory.push(2, at: now.addingTimeInterval(-20))
        memory.push(3, at: now.addingTimeInterval(-10))
        check(memory.pop(now: now, ttl: 300, isStillValid: { _ in true }) == 3,
              "还原先捞最后一个被最小化的")
        check(memory.pop(now: now, ttl: 300, isStillValid: { _ in true }) == 2,
              "再还原一次捞倒数第二个")
        check(memory.pop(now: now, ttl: 300, isStillValid: { _ in true }) == 1,
              "第三次捞最早那个")
        check(memory.pop(now: now, ttl: 300, isStillValid: { _ in true }) == nil,
              "捞完了就没了，不能凭空变出窗口")

        // 过期的不还原
        var expired = MinimizeMemory<Int>()
        expired.push(9, at: now.addingTimeInterval(-400))
        check(expired.pop(now: now, ttl: 300, isStillValid: { _ in true }) == nil,
              "超过记忆期的记录不再还原")

        // 已经被用户手动恢复 / 关掉的窗口跳过
        var stale = MinimizeMemory<Int>()
        stale.push(7, at: now)
        check(stale.pop(now: now, ttl: 300, isStillValid: { _ in false }) == nil,
              "已经不在了的窗口直接跳过")

        // 上限：只留最近几条
        var capped = MinimizeMemory<Int>(limit: 3)
        for value in 1...5 { capped.push(value, at: now) }
        check(capped.count == 3, "记忆条数有上限")
        check(capped.pop(now: now, ttl: 300, isStillValid: { _ in true }) == 5,
              "超上限时丢最旧的，最新那条还在")

        var candidate = MinimizeMemory<Int>()
        candidate.push(1, at: now.addingTimeInterval(-400))
        check(!candidate.hasCandidate(now: now, ttl: 300), "过期记录不算候选")

        // 手势结束后的屏幕反馈：两个开关管什么、不管什么
        check(FeedbackHUD.shouldShow(.success("最小化"), showSuccess: true, showUnmatched: true),
              "成功提示开着就显示手势名")
        check(!FeedbackHUD.shouldShow(.success("最小化"), showSuccess: false, showUnmatched: true),
              "关掉成功提示后不再打扰")
        check(!FeedbackHUD.shouldShow(.unmatched, showSuccess: true, showUnmatched: false),
              "关掉未识别提示后画歪了也不吭声")
        check(FeedbackHUD.shouldShow(.failure("最小化"), showSuccess: false, showUnmatched: false),
              "执行失败必须提示，不受两个开关影响")

        // 两个新开关的默认值与持久化
        var feedback = BoxMouseSettings()
        check(feedback.showSuccessFeedback, "成功匹配提示默认开启")
        check(feedback.showUnrecognizedFeedback, "未识别手势提示默认开启")
        feedback.showSuccessFeedback = false
        feedback.showUnrecognizedFeedback = false
        if let data = try? JSONEncoder().encode(feedback),
           let decoded = try? JSONDecoder().decode(BoxMouseSettings.self, from: data) {
            check(!decoded.showSuccessFeedback && !decoded.showUnrecognizedFeedback,
                  "两个反馈开关能持久化")
        } else {
            check(false, "反馈设置编码/解码失败")
        }

        // 往返：编码出来还得能读回去
        if let data = try? JSONEncoder().encode(WindowOp.restore),
           let back = try? JSONDecoder().decode(WindowOp.self, from: data) {
            check(back == .restore, "窗口操作编解码往返一致")
        } else {
            check(false, "窗口操作编解码往返一致")
        }
    }

    // MARK: - 修饰键

    /// 修饰键是「跟手势叠加的条件」，不是另一种触发方式。
    ///
    /// 盯四件事：
    ///   ① 从 CGEvent 的 flags 能准确解出按住的键，且不受无关 flag 位干扰；
    ///   ② 候选按修饰键**全等**匹配——建了「⌘ + 右键」不能把裸右键那条也带走；
    ///   ③ 老配置里 trigger 写成 command/fn 这类值的，迁移成「右键 + 该修饰键」；
    ///   ④ 编解码往返不丢修饰键。
    private static func testModifiers() {
        // ① flags → 集合
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        check(ModifierKey.set(from: cmdShift) == [.command, .shift],
              "⌘⇧ 能解出两个修饰键（实际 \(ModifierKey.describe(ModifierKey.set(from: cmdShift)))）")
        check(ModifierKey.set(from: []).isEmpty, "没按修饰键时解出空集")
        // 真实事件里 flags 混着 maskNonCoalesced 之类的无关位，不能因此判错
        let dirty: CGEventFlags = [.maskCommand, .maskNonCoalesced, .maskNumericPad]
        check(ModifierKey.set(from: dirty) == [.command],
              "无关的 flags 位不影响判定（实际 \(ModifierKey.describe(ModifierKey.set(from: dirty)))）")

        // 缩写按固定顺序拼，否则表格里的列会随进程变化闪
        check(ModifierKey.describe([.shift, .command]) == "⌘⇧",
              "修饰键缩写按固定顺序拼（实际 \(ModifierKey.describe([.shift, .command]))）")

        // ② 全等匹配
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-mod-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)
        let scope = store.globalScope.id

        let bare = Gesture(name: "裸右键",
                           trigger: .rightButton,
                           action: .window(.close),
                           scopeID: scope,
                           path: PathRecognizer.normalize([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]))
        var withCmd = bare
        withCmd.id = UUID()
        withCmd.name = "⌘ + 右键"
        withCmd.modifiers = [.command]
        store.add(bare)
        store.add(withCmd)

        let plain = Set(store.candidates(trigger: .rightButton, modifiers: [], bundleID: "com.apple.Safari").map(\.id))
        check(plain.contains(bare.id) && !plain.contains(withCmd.id),
              "裸右键的候选里没有「⌘ + 右键」那条")

        let combo = Set(store.candidates(trigger: .rightButton,
                                        modifiers: [.command],
                                        bundleID: "com.apple.Safari").map(\.id))
        check(combo.contains(withCmd.id) && !combo.contains(bare.id),
              "⌘ + 右键的候选里没有裸右键那条")

        check(withCmd.triggerDescription == "⌘ + 右键",
              "表格里的触发键写全了修饰键（实际 \(withCmd.triggerDescription)）")
        check(bare.triggerDescription == "右键",
              "没有修饰键时只写鼠标键（实际 \(bare.triggerDescription)）")

        // ③ 老配置迁移：以前 trigger 直接写成 "command"
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"老的 ⌘ 手势","enabled":true,"trigger":"command",
         "action":{"kind":"window","windowOp":"close"},
         "scopeID":"\(scope.uuidString)","path":[],
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let migrated = try? decoder.decode(Gesture.self, from: Data(legacyJSON.utf8)) {
            check(migrated.trigger == .rightButton && migrated.modifiers == [.command],
                  "老配置的 command 触发迁移成「右键 + ⌘」（实际 \(migrated.triggerDescription)）")
        } else {
            check(false, "老配置能解码")
        }

        // ④ 往返
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(withCmd),
           let back = try? decoder.decode(Gesture.self, from: data) {
            check(back.modifiers == [.command], "修饰键编解码往返一致")
        } else {
            check(false, "带修饰键的手势能编解码")
        }

        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - 触摸板手势

    /// 触摸板手势和鼠标手势是两套触发条件，最怕的就是互相串场：
    /// 鼠标画一笔莫名触发「3 指轻点」，或者两条定义抢同一次触摸。
    private static func testTrackpad() {
        // ① 表格里那一列短描述，写法必须稳定
        check(TrackpadSpec.tap(fingers: 3).summary == "3 指轻点",
              "轻点的短描述（实际 \(TrackpadSpec.tap(fingers: 3).summary)）")
        check(TrackpadSpec.swipe(fingers: 4, .up).summary == "4 指上滑",
              "滑动的短描述（实际 \(TrackpadSpec.swipe(fingers: 4, .up).summary)）")
        check(TrackpadSpec.pinchIn().summary == "两指捏合",
              "捏合的短描述（实际 \(TrackpadSpec.pinchIn().summary)）")
        check(TrackpadSpec.pinchOut().summary == "两指张开",
              "张开的短描述（实际 \(TrackpadSpec.pinchOut().summary)）")
        // 捏合固定两指，编辑器里手指数是锁死的，模型层也不能自己漂
        check(TrackpadSpec.pinchIn().fingers == 2 && TrackpadSpec.pinchIn().pattern.fixesTwoFingers,
              "捏合固定两指")

        // ①b 单指只允许轻点：一根手指在触控板上就是移动指针
        let oneFingerSwipe = TrackpadSpec(fingers: 1, pattern: .swipe, direction: .left).sanitized()
        check(oneFingerSwipe.fingers == 1 && oneFingerSwipe.pattern == .tap,
              "单指的滑动会被修成轻点（实际 \(oneFingerSwipe.summary)）")
        let oneFingerTap = TrackpadSpec.tap(fingers: 1)
        check(oneFingerTap.summary == "1 指轻点",
              "单指轻点的短描述（实际 \(oneFingerTap.summary)）")
        // 捏合必须回落到两指，方向必须清掉
        let messy = TrackpadSpec(fingers: 4, pattern: .pinchIn, direction: .up).sanitized()
        check(messy.fingers == 2 && messy.direction == nil,
              "捏合会修成两指且不带方向（实际 \(messy.summary)）")
        // 滑动缺方向时要补一个默认值，不能存成 nil
        let swipeNoDirection = TrackpadSpec(fingers: 3, pattern: .swipe, direction: nil).sanitized()
        check(swipeNoDirection.direction == .up,
              "滑动缺方向补默认上滑（实际 \(swipeNoDirection.summary)）")

        // ② 匹配：手指数、方向、捏合方向都不能串
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-tp-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)
        // 临时目录是空的，init 会灌出厂手势——先清干净，否则候选里混着示例
        store.delete(ids: Set(store.gestures.map(\.id)))
        let global = store.globalScope.id

        let tap3 = Gesture.trackpadGesture(name: "三指轻点", spec: .tap(fingers: 3),
                                           action: .window(.minimize), scopeID: global)
        let swipe4 = Gesture.trackpadGesture(name: "四指上滑", spec: .swipe(fingers: 4, .up),
                                             action: .window(.fullScreen), scopeID: global)
        let pinch = Gesture.trackpadGesture(name: "两指捏合", spec: .pinchIn(),
                                            action: .window(.close), scopeID: global)
        store.add(tap3)
        store.add(swipe4)
        store.add(pinch)

        func hit(_ event: TrackpadEvent, bundleID: String? = "com.apple.Safari") -> Set<UUID> {
            Set(store.trackpadCandidates(event: event, bundleID: bundleID).map(\.id))
        }

        let threeTap = hit(.tap(fingers: 3))
        check(threeTap.contains(tap3.id), "3 指轻点命中「三指轻点」")
        check(!threeTap.contains(swipe4.id), "3 指轻点不会命中「四指上滑」")

        let fourTap = hit(.tap(fingers: 4))
        check(fourTap.isEmpty, "4 指轻点没有定义（实际命中 \(fourTap.count) 条）")

        let upSwipe = hit(.swipe(fingers: 4, direction: .up))
        check(upSwipe.contains(swipe4.id), "4 指上滑命中「四指上滑」")
        let downSwipe = hit(.swipe(fingers: 4, direction: .down))
        check(!downSwipe.contains(swipe4.id), "4 指下滑不会命中「四指上滑」")
        let twoUpSwipe = hit(.swipe(fingers: 2, direction: .up))
        check(!twoUpSwipe.contains(swipe4.id), "2 指上滑不会命中「四指上滑」")

        // 捏合只看方向不看比例：每个人张合的幅度差很多，用比例匹配会时灵时不灵
        check(hit(.pinch(spreadRatio: 0.6)).contains(pinch.id), "合拢命中「两指捏合」")
        check(hit(.pinch(spreadRatio: 1.8)).contains(pinch.id) == false, "张开会命中捏合就是错的")
        check(hit(.pinch(spreadRatio: 0.6)).count == 1, "一次合拢只该命中一条")

        // ③ 两套触发条件不能互相串场
        let mouseCandidates = Set(store.candidates(trigger: .rightButton, modifiers: [],
                                                   bundleID: "com.apple.Safari").map(\.id))
        check(mouseCandidates.isEmpty, "触摸板手势不会进鼠标候选（实际 \(mouseCandidates.count) 条）")
        check(!store.hasEnabledGesture(trigger: .rightButton),
              "只有触摸板手势时不该吞掉右键")

        let mouseOne = Gesture(name: "右键画 L", trigger: .rightButton,
                               action: .window(.close), scopeID: global,
                               path: PathRecognizer.normalize([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]))
        store.add(mouseOne)
        check(hit(.tap(fingers: 3)).count == 1, "加了鼠标手势之后触摸板候选还是只有一条")

        // ④ 应用级优先于全局：同一个「3 指轻点」在某个应用里另有定义时，那个应用先命中
        let safariScope = store.addAppScope(name: "Safari", bundleID: "com.apple.Safari")
        let tap3InSafari = Gesture.trackpadGesture(name: "Safari 三指轻点", spec: .tap(fingers: 3),
                                                   action: .window(.close), scopeID: safariScope.id)
        store.add(tap3InSafari)
        let ordered = store.trackpadCandidates(event: .tap(fingers: 3), bundleID: "com.apple.Safari")
        check(ordered.first?.id == tap3InSafari.id, "应用级手势排在全局前面")
        check(ordered.count == 2, "两条候选都保留（实际 \(ordered.count) 条）")
        // 别的应用只拿到全局那条
        let elsewhere = store.trackpadCandidates(event: .tap(fingers: 3), bundleID: "com.apple.Notes")
        check(elsewhere.map(\.id) == [tap3.id], "非作用域内的应用只命中全局那条")

        // ④b 单指轻点也能命中
        let tap1 = Gesture.trackpadGesture(name: "单指轻点", spec: .tap(fingers: 1),
                                           action: .window(.close), scopeID: global)
        store.add(tap1)
        check(hit(.tap(fingers: 1)).contains(tap1.id), "1 指轻点命中「单指轻点」")
        check(!hit(.tap(fingers: 1)).contains(tap3.id), "1 指轻点不会命中「三指轻点」")

        // ④c 修饰键是叠加条件，全等匹配
        var tap3WithFn = tap3
        tap3WithFn.id = UUID()
        tap3WithFn.name = "Fn + 三指轻点"
        tap3WithFn.modifiers = [.fn]
        store.add(tap3WithFn)
        let bare = hit(.tap(fingers: 3))
        check(bare.contains(tap3.id) && !bare.contains(tap3WithFn.id),
              "不按修饰键时不会命中「Fn + 三指轻点」")
        let withFn = Set(store.trackpadCandidates(event: .tap(fingers: 3),
                                                  modifiers: [.fn],
                                                  bundleID: "com.apple.Safari").map(\.id))
        check(withFn.contains(tap3WithFn.id) && !withFn.contains(tap3.id),
              "按着 Fn 时只命中带 Fn 的那条")
        // 收尾：这两条别影响后面的计数断言
        store.delete(ids: [tap1.id, tap3WithFn.id])

        // ⑤ 关掉就不该再命中
        store.setEnabled(false, ids: [tap3InSafari.id])
        let afterDisable = store.trackpadCandidates(event: .tap(fingers: 3), bundleID: "com.apple.Safari")
        check(afterDisable.map(\.id) == [tap3.id], "停用后应用级那条不再命中")

        // ⑥ 老配置没有 kind 字段
        let legacyJSON = """
        {"id":"\(UUID().uuidString)","name":"老的手势","enabled":true,"trigger":"rightButton",
         "action":{"kind":"window","windowOp":"close"},
         "scopeID":"\(global.uuidString)","path":[],
         "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let migrated = try? decoder.decode(Gesture.self, from: Data(legacyJSON.utf8)) {
            check(migrated.kind == .mouse && migrated.trackpad == nil,
                  "缺 kind 字段的老配置按鼠标手势解码")
        } else {
            check(false, "缺 kind 字段的老配置能解码")
        }

        // ⑦ 编解码往返
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(swipe4),
           let back = try? decoder.decode(Gesture.self, from: data) {
            check(back.kind == .trackpad && back.trackpad == swipe4.trackpad,
                  "触摸板手势编解码往返一致（实际 \(back.triggerDescription)）")
        } else {
            check(false, "触摸板手势能编解码")
        }

        // 表格那一列写的就是短描述，不能写成「右键」
        check(swipe4.triggerDescription == "4 指上滑",
              "触摸板手势的触发描述用短描述（实际 \(swipe4.triggerDescription)）")

        try? FileManager.default.removeItem(at: temp)
    }

    private static func testMenuBarIcon() {        let icon = MenuBarIcon.make()
        check(icon.size == NSSize(width: 18, height: 18), "菜单栏图标逻辑尺寸 18×18（实际 \(icon.size)）")
        check(icon.isTemplate, "菜单栏图标是 template（跟随菜单栏明暗自动上色）")
        check(icon.representations.first?.pixelsWide == 36,
              "菜单栏图标按 2 倍像素绘制（实际 \(icon.representations.first?.pixelsWide ?? -1)px），否则 Retina 下发糊")

        // 字形必须真的画了东西：全透明的图在菜单栏上等于没有图标。
        // 每个变体都要查——只查默认的那个，改几何时把别的变体画空了也发现不了。
        for variant in MenuBarGlyphVariant.allCases {
            let alpha = MenuBarIcon.inkCoverage(variant: variant)
            check(alpha > 0.08 && alpha < 0.92,
                  "变体「\(variant.title)」墨迹覆盖 \(String(format: "%.0f%%", alpha * 100))，"
                  + "既不是空白也不是一块实心方")
        }
    }

    // MARK: - 浏览器操作
    /// 浏览器操作是这次新加的动作类型，要保证：
    /// ① 每个操作都有能发出去的按键（漏一个就是"点了没反应"）
    /// ② 复制链接是两步，两步都在
    /// ③ 编解码往返不丢字段
    /// ④ 老配置（没有 browserOp 这个键）还能解出来
    private static func testBrowserOps() {
        for op in BrowserOp.allCases {
            let combos = op.keyCombos
            check(!combos.isEmpty, "浏览器操作「\(op.displayName)」有对应的按键")
            check(combos.allSatisfy { $0.keyCode > 0 && $0.flags > 0 },
                  "浏览器操作「\(op.displayName)」的按键键码与修饰键都有效")
            check(combos.allSatisfy { !$0.display.isEmpty },
                  "浏览器操作「\(op.displayName)」有显示文本")
        }

        check(BrowserOp.copyURL.keyCombos.count == 2,
              "复制当前页链接是两步（⌘L 选中地址栏 → ⌘C），不是单键")
        check(BrowserOp.copyURL.keyCombos[0].display == "⌘L"
              && BrowserOp.copyURL.keyCombos[1].display == "⌘C",
              "复制当前页链接的顺序是 ⌘L → ⌘C")

        let action = GestureAction.browser(.reload)
        check(action.kind == .browser && action.browserOp == .reload,
              "浏览器动作的 kind 与操作都存得进去")
        check(action.isValid, "浏览器动作算完整（可以保存）")
        check(action.summary.contains("刷新页面"),
              "浏览器动作的摘要写的是操作名（实际 \(action.summary)）")

        if let data = try? JSONEncoder().encode(action),
           let back = try? JSONDecoder().decode(GestureAction.self, from: data) {
            check(back.kind == .browser && back.browserOp == .reload,
                  "浏览器动作编解码往返一致")
        } else {
            check(false, "浏览器动作能编解码")
        }

        // 老配置里根本没有 browserOp 这个键，解码必须回落成 nil，不能整份配置报废
        let legacy = #"{"kind":"keystroke","keyCombo":{"keyCode":49,"flags":256,"display":"空格"}}"#
        if let data = legacy.data(using: .utf8),
           let back = try? JSONDecoder().decode(GestureAction.self, from: data) {
            check(back.kind == .keystroke && back.browserOp == nil,
                  "老配置（没有 browserOp 字段）照样能解码")
        } else {
            check(false, "老配置能解码")
        }
    }

    // MARK: - 触摸板识别器（合成数据）

    /// 折线手势（用户「刷新」：闪电 / Z 形）必须一次命中。
    ///
    /// 用户报的就是这个：「这种线条手势识别不是很准，要好几次才行」。
    /// 旧算法的病根：按轴缩放破坏角度 + 8 方位量化在 ±22.5° 边界附近
    /// 对臂长比例极敏感（`→↘↙↘→` vs `→↓↘`）。新算法（等比缩放 + DTW +
    /// RDP 段角度 + 四路多尝试）是数值实验定案的，实验里 25 个手绘变体
    /// 最差 0.794、6 类形状两两负例最高 0.629 —— 这里把同一组数据固化下来。
    private static func testZigzagRecognition() {
        let lightning: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40), CGPoint(x: 40, y: 120), CGPoint(x: 140, y: 160)]
        let zshape: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 0), CGPoint(x: 0, y: 90), CGPoint(x: 120, y: 90)]

        func smooth(_ pts: [CGPoint], k: Int = 6) -> [CGPoint] {
            var out = [pts[0]]
            for i in 1..<pts.count {
                for t in 1..<k {
                    let r = CGFloat(t) / CGFloat(k)
                    out.append(CGPoint(x: pts[i-1].x + (pts[i].x - pts[i-1].x) * r,
                                       y: pts[i-1].y + (pts[i].y - pts[i-1].y) * r))
                }
                out.append(pts[i])
            }
            return out
        }

        func tilted(_ pts: [CGPoint]) -> [CGPoint] {
            pts.map { CGPoint(x: $0.x + $0.y * 0.15, y: $0.y) }
        }

        func hook(_ pts: [CGPoint]) -> [CGPoint] {
            [CGPoint(x: -8, y: -10)] + pts
        }

        let cases: [(String, [CGPoint], [(String, [CGPoint])])] = [
            ("闪电", lightning, [
                ("臂长变体", [CGPoint(x: 0, y: 0), CGPoint(x: 150, y: 60), CGPoint(x: 60, y: 120), CGPoint(x: 150, y: 170)]),
                ("转角圆滑", smooth(lightning)),
                ("起笔小勾", hook(lightning)),
                ("整体倾斜", tilted(lightning)),
                ("转角漂移", [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 55), CGPoint(x: 55, y: 100), CGPoint(x: 140, y: 160)]),
            ]),
            ("Z形", zshape, [
                ("臂长变体", [CGPoint(x: 0, y: 0), CGPoint(x: 180, y: 0), CGPoint(x: 0, y: 130), CGPoint(x: 180, y: 130)]),
                ("转角圆滑", smooth(zshape)),
                ("起笔小勾", hook(zshape)),
                ("整体倾斜", tilted(zshape)),
                ("转角漂移", [CGPoint(x: 0, y: 0), CGPoint(x: 120, y: 15), CGPoint(x: 15, y: 90), CGPoint(x: 120, y: 90)]),
            ]),
        ]

        for (name, template, variants) in cases {
            let tn = PathRecognizer.normalize(template)
            for (vname, pts) in variants {
                let vn = PathRecognizer.normalize(pts)
                let s = PathRecognizer.score(vn, tn)
                check(s >= PathRecognizer.matchThreshold,
                      "\(name)·\(vname) 一次命中（\(String(format: "%.3f", s))）")
            }
        }

        // 负例：六类形状两两之间不许互相误判。
        // 「反向闪电」用三段方向全反的形状（← ↗ ←）——同向但中间臂更平缓的
        // 变体其实是同一个闪电的另一种画法，手画时区分不开，不能当负例。
        let shapes: [(String, [CGPoint])] = [
            ("闪电", lightning),
            ("Z形", zshape),
            ("L形", [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 120), CGPoint(x: 90, y: 120)]),
            ("直线", [CGPoint(x: 0, y: 0), CGPoint(x: 160, y: 20)]),
            ("弧线", (0...16).map { CGPoint(x: CGFloat($0) * 10, y: sin(CGFloat($0) / 16 * .pi) * 60) }),
            ("反向闪电", [CGPoint(x: 160, y: 0), CGPoint(x: 40, y: 50), CGPoint(x: 120, y: 110), CGPoint(x: 0, y: 160)]),
        ]
        for i in 0..<shapes.count {
            for j in (i + 1)..<shapes.count {
                let sa = PathRecognizer.normalize(shapes[i].1)
                let sb = PathRecognizer.normalize(shapes[j].1)
                let s = PathRecognizer.score(sa, sb)
                check(s < PathRecognizer.matchThreshold,
                      "\(shapes[i].0) 不误判成 \(shapes[j].0)（\(String(format: "%.3f", s))）")
            }
        }
    }

    /// 斜线手势「画得不够角度」也要认得出（用户 1.0.22 的反馈）。
    ///
    /// 「还原」模板走向 41°，手一抖只画出 25° 就认不出了——前四路对纯旋转太敏感。
    /// 第五路「直线走向」把容差拉到 ±27° 左右；
    /// 但同作用域里最近的另一条直线（右半屏 0°）只差 41°，所以不能放得太宽。
    private static func testDiagonalAngleTolerance() {
        func line(angle degrees: Double, length: Double = 200) -> [CGPoint] {
            let radians = degrees * .pi / 180
            return (0...40).map { index in
                let distance = CGFloat(Double(index) / 40 * length)
                return CGPoint(x: distance * cos(radians), y: distance * sin(radians))
            }
        }

        /// 把直线弯成弧：中段垂直于弦偏移 bulge（相对弦长的比例）
        func arc(bulge: Double, angle degrees: Double) -> [CGPoint] {
            let radians = degrees * .pi / 180
            let nx = -sin(radians)
            let ny = cos(radians)
            return (0...40).map { index in
                let t = Double(index) / 40
                let distance = CGFloat(t * 200)
                let offset = CGFloat(sin(.pi * t) * bulge * 200)
                return CGPoint(x: distance * cos(radians) + offset * nx,
                               y: distance * sin(radians) + offset * ny)
            }
        }

        let template = PathRecognizer.normalize(line(angle: 41))

        // 正例：走向偏到 ±25° 都还得认出来（以前 ±12° 就已经 0.816 贴着阈值走了）
        for offset in [0.0, 7, 15, 20, 25, -7, -15, -20, -25] {
            let drawn = PathRecognizer.normalize(line(angle: 41 + offset))
            let value = PathRecognizer.score(drawn, template)
            check(value >= PathRecognizer.matchThreshold,
                  "斜线走向偏 \(Int(offset))° 仍命中（\(String(format: "%.3f", value))）")
        }

        // 负例：偏 35° 以上就是另一条线了，不许认
        for offset in [35.0, -35] {
            let drawn = PathRecognizer.normalize(line(angle: 41 + offset))
            let value = PathRecognizer.score(drawn, template)
            check(value < PathRecognizer.matchThreshold,
                  "斜线走向偏 \(Int(offset))° 不命中（\(String(format: "%.3f", value))）")
        }

        // 负例：同作用域里最近的邻居是水平线（右半屏），差 41°，必须分得开
        let horizontal = PathRecognizer.normalize(line(angle: 0))
        let crossScore = PathRecognizer.score(horizontal, template)
        check(crossScore < PathRecognizer.matchThreshold,
              "水平线不当成 41° 斜线（\(String(format: "%.3f", crossScore))）")

        // 负例：反着画（↙ vs ↗）方向完全不同
        let reversed = PathRecognizer.normalize(line(angle: 221))
        check(PathRecognizer.score(reversed, template) < PathRecognizer.matchThreshold,
              "反向斜线不命中")

        // 正例：手画斜线常带弧度（手腕绕肘部转），弯 12% 仍算直线；
        // 负例：弯 20% 就是一条弧，不能再当直线
        let slightArc = PathRecognizer.normalize(arc(bulge: 0.12, angle: 41))
        check(PathRecognizer.score(slightArc, template) >= PathRecognizer.matchThreshold,
              "手画斜线的 12% 弧度仍命中")
        let bigArc = PathRecognizer.normalize(arc(bulge: 0.20, angle: 41))
        check(PathRecognizer.score(bigArc, template) < PathRecognizer.matchThreshold,
              "20% 弧度不再算斜线")

        // 对称性：镜像的两条斜线必须同一待遇（绝对值阈值曾让「还原」算直线、「最小化」不算）
        let mirroredTemplate = PathRecognizer.normalize(line(angle: 180 - 41 + 360))
        let mirroredDrawn = PathRecognizer.normalize(line(angle: 180 - 41 - 20 + 360))
        let mirroredValue = PathRecognizer.score(mirroredDrawn, mirroredTemplate)
        check(mirroredValue >= PathRecognizer.matchThreshold,
              "镜像斜线同样容得下 20° 偏差（\(String(format: "%.3f", mirroredValue))）")

        // 这一路的适用边界：折线（闪电）不参与，仍走前四路
        let lightning: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40), CGPoint(x: 40, y: 120), CGPoint(x: 140, y: 160)]
        let bent = PathRecognizer.normalize(lightning)
        check(PathRecognizer.score(bent, template) < PathRecognizer.matchThreshold,
              "折线不被 41° 斜线抢走")
    }

    /// 表格「触发」列要把修饰键写全（用户报「文字少了修饰键」）。
    private static func testTriggerDescriptionShowsModifiers() {
        let gesture = Gesture.trackpadGesture(name: "三指轻点", spec: .tap(fingers: 3),
                                              action: .window(.close), scopeID: UUID())
        var withFn = gesture
        withFn.modifiers = [.fn]
        let expected = "\(ModifierKey.describe([.fn])) + 3 指轻点"
        check(withFn.triggerDescription == expected,
              "触摸板手势的触发列带修饰键（实际 \(withFn.triggerDescription)）")
        check(gesture.triggerDescription == "3 指轻点",
              "没有修饰键时只写触摸板描述（实际 \(gesture.triggerDescription)）")
    }

    /// 触摸板「画轨迹」端到端：合成触点帧 → 识别出 .path → 候选命中。
    ///
    /// 这是 1.0.12 新增的形态。三个独立风险各断一条：
    /// ① 识别器把画轨迹误判成轻点（或反过来）；
    /// ② 轨迹匹配没对上模板（坐标系 / 归一化接错）；
    /// ③ 编辑器的 sanitized 约束失效（画轨迹配成多指）。
    private static func testTrackpadPathGesture() {
        // 画一条闪电（触控板坐标 y 向远端为正，所以喂点时 y 取负）
        // 目标形状（屏幕方向，y 向下）：(0,0)→(100,40)→(40,120)→(140,160)
        let shape: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: -40),
            CGPoint(x: 40, y: -120), CGPoint(x: 140, y: -160),
        ]
        func along(_ pts: [CGPoint], steps: Int) -> [CGPoint] {
            var out: [CGPoint] = []
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps - 1) * 3 // 走完 3 段
                let seg = min(2, Int(t))
                let r = t - CGFloat(seg)
                let a = pts[seg], b = pts[seg + 1]
                out.append(CGPoint(x: a.x + (b.x - a.x) * r,
                                   y: a.y + (b.y - a.y) * r))
            }
            return out
        }
        let scale: CGFloat = 1.0 / 200.0
        let drawn = along(shape, steps: 30).map {
            CGPoint(x: $0.x * scale + 0.5, y: $0.y * scale + 0.5)
        }
        let frames = drawn.map { (fingers: 1, points: [$0]) }

        // ① 识别器给出 .path 事件
        if let report = TrackpadSelfTest.recognize(frames) {
            guard case .path(let points) = report.event else {
                check(false, "画轨迹被识别成 \(report.event)")
                return
            }
            check(points.count >= 6, "画轨迹采到了足够的点（\(points.count) 个）")

            // ② 候选匹配：模板就是这条闪电时命中；画成直线时不命中
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("selftest-path-\(UUID().uuidString)")
            let store = GestureStore(directory: temp)
            defer { try? FileManager.default.removeItem(at: temp) }
            let global = store.scopes[0].id
            var spec = TrackpadSpec(fingers: 1, pattern: .path, direction: nil, path: [], rawPath: nil)
            spec.path = PathRecognizer.normalize(shape.map { CGPoint(x: $0.x, y: -$0.y) })
            // 画轨迹必须带修饰键（见 testTrackpadPathRequiresModifier）
            var gesture = Gesture.trackpadGesture(name: "触摸板闪电", spec: spec,
                                                  action: .window(.close), scopeID: global)
            gesture.modifiers = [.fn]
            store.add(gesture)

            let hit = store.trackpadCandidates(event: .path(points), modifiers: [.fn], bundleID: nil)
            check(!hit.isEmpty, "画出的闪电命中「触摸板闪电」手势")

            let straight = (0..<30).map { i in
                CGPoint(x: 0.2 + CGFloat(i) * 0.012, y: 0.5)
            }
            let miss = store.trackpadCandidates(event: .path(straight), modifiers: [.fn], bundleID: nil)
            check(miss.isEmpty, "画直线不会命中闪电手势")
        } else {
            check(false, "画轨迹能被识别出来（实际返回 nil）")
        }

        // ③ 轻点不会被当成画轨迹：只落指几乎不动
        let tapFrames = (0..<5).map { i in
            (fingers: 1, points: [CGPoint(x: 0.5 + CGFloat(i) * 0.001, y: 0.5)])
        }
        if let report = TrackpadSelfTest.recognize(tapFrames) {
            if case .path = report.event {
                check(false, "轻点不会被当成画轨迹")
            } else {
                check(true, "轻点仍然是轻点")
            }
        } else {
            check(true, "轻点没有被误判成画轨迹")
        }

        // ④ sanitized：画轨迹强制单指
        var multi = TrackpadSpec(fingers: 3, pattern: .path, direction: nil, path: [], rawPath: nil)
        multi = multi.sanitized()
        check(multi.fingers == 1 && multi.pattern == .path,
              "画轨迹的多指配置被修平成单指（实际 \(multi.fingers) 指）")
        check(multi.summary == "画轨迹", "画轨迹的短描述（实际 \(multi.summary)）")
    }

    /// 画轨迹必须带修饰键（用户要求：设置时必须选一个）。
    ///
    /// 裸单指在触控板上就是移动指针，每一段指针移动都会被攒成轨迹并触发动作，
    /// 等于把整个触控板的正常使用废掉。编辑器禁保存 + store 匹配层再挡一道。
    private static func testTrackpadPathRequiresModifier() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("selftest-pathmod-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)
        defer { try? FileManager.default.removeItem(at: temp) }
        let global = store.scopes[0].id

        let lightning: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 40),
            CGPoint(x: 40, y: 120), CGPoint(x: 140, y: 160),
        ]
        let template = PathRecognizer.normalize(lightning)
        let event = TrackpadEvent.path(lightning)

        // 裸画轨迹（无修饰键）：不允许命中
        var bare = TrackpadSpec(fingers: 1, pattern: .path, direction: nil,
                                path: template, rawPath: nil)
        bare = bare.sanitized()
        let bareGesture = Gesture.trackpadGesture(name: "裸画轨迹", spec: bare,
                                                  action: .window(.close), scopeID: global)
        store.add(bareGesture)
        check(store.trackpadCandidates(event: event, modifiers: [], bundleID: nil).isEmpty,
              "没修饰键的画轨迹手势不会命中")

        // 带 Fn 的画轨迹：命中
        var withFn = Gesture.trackpadGesture(name: "Fn 画轨迹",
                                             spec: TrackpadSpec(fingers: 1, pattern: .path,
                                                                direction: nil, path: template,
                                                                rawPath: nil),
                                             action: .window(.close), scopeID: global)
        withFn.modifiers = [.fn]
        store.add(withFn)
        let hit = store.trackpadCandidates(event: event, modifiers: [.fn], bundleID: nil)
        check(hit.map(\.id) == [withFn.id],
              "按住 Fn 时命中「Fn 画轨迹」（命中 \(hit.map(\.name))）")
    }

    /// 触摸板轨迹在屏幕上的映射：方向不能反、比例要对。
    ///
    /// 触控板坐标在引擎里已经翻成屏幕方向（向下为正），映射只做平移 + 等比放大。
    private static func testTrackpadTrailMapping() {
        let anchor = CGPoint(x: 400, y: 300)
        let origin = CGPoint(x: 0.5, y: 0)      // 触控板正中起手
        let scale: CGFloat = 400

        let right = AppModel.trailScreenPoint(CGPoint(x: 0.75, y: 0), origin: origin,
                                              anchor: anchor, scale: scale)
        check(abs(right.x - 500) < 0.01 && abs(right.y - 300) < 0.01,
              "触控板向右 25% → 屏幕向右 100pt（实际 \(right.x), \(right.y)）")

        // y 已翻成屏幕方向：触控板向下画（y 增大）→ 屏幕 y 也增大
        let down = AppModel.trailScreenPoint(CGPoint(x: 0.5, y: 0.25), origin: origin,
                                             anchor: anchor, scale: scale)
        check(abs(down.y - 400) < 0.01,
              "触控板向下 25% → 屏幕向下 100pt（实际 \(down.y)）")

        // 起手点本身必须落在锚点上
        let same = AppModel.trailScreenPoint(origin, origin: origin, anchor: anchor, scale: scale)
        check(abs(same.x - anchor.x) < 0.01 && abs(same.y - anchor.y) < 0.01,
              "起手点映射到指针位置")
    }

    /// 触摸板引擎按需启停：没启用的触摸板手势就不该挂着设备、跑定时器。
    private static func testTrackpadEngineLifecycle() {
        let spec = TrackpadSpec.tap(fingers: 3)
        var trackpadGesture = Gesture.trackpadGesture(name: "三指轻点", spec: spec,
                                                      action: .window(.close), scopeID: UUID())
        trackpadGesture.enabled = false

        check(!TrackpadEngine.shouldRun(engineEnabled: true, gestures: [trackpadGesture]),
              "触摸板手势全停用时引擎不启动")
        trackpadGesture.enabled = true
        check(TrackpadEngine.shouldRun(engineEnabled: true, gestures: [trackpadGesture]),
              "启用触摸板手势后引擎启动")
        check(!TrackpadEngine.shouldRun(engineEnabled: false, gestures: [trackpadGesture]),
              "总开关关闭时引擎不启动")

        // 鼠标手势不该把触摸板引擎拉起来
        let mouse = Gesture(name: "右键画线", trigger: .rightButton,
                            action: .window(.close), scopeID: UUID(),
                            path: PathRecognizer.normalize([CGPoint(x: 0, y: 0),
                                                            CGPoint(x: 1, y: 1)]))
        check(!TrackpadEngine.shouldRun(engineEnabled: true, gestures: [mouse]),
              "只有鼠标手势时触摸板引擎不启动")
    }

    /// 应用选择器要能认出「替身」。
    ///
    /// 豆包浏览器把自己藏在 `Doubao.app/Contents/Helpers/Doubao Browser.app`，
    /// 用户在「应用程序」里只放得下一个 952 字节的替身文件——
    /// 那根本不是目录，`Bundle(path:)` 返回 nil，搜索里就永远看不到它。
    private static func testAppAliasResolution() {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("boxmouse-alias-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        let realApp = root.appendingPathComponent("真身.app")
        let contents = realApp.appendingPathComponent("Contents")
        do {
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
        } catch {
            check(false, "替身解析：造测试目录失败")
            return
        }
        let plist: [String: Any] = ["CFBundleIdentifier": "com.boxmouse.test.alias",
                                    "CFBundleName": "真身",
                                    "CFBundlePackageType": "APPL"]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        check(Bundle(path: realApp.path) != nil, "替身解析：测试用假 app 得先被认成 bundle")

        let aliasFile = root.appendingPathComponent("替身.app")
        if let data = try? realApp.bookmarkData() {
            try? data.write(to: aliasFile)
        }
        // 注意比 canonical 路径：临时目录在 /var 下，解析出来常是 /private/var
        let expected = realApp.resolvingSymlinksInPath().path
        let got = InstalledApps.resolveAlias(aliasFile)?.resolvingSymlinksInPath().path
        check(got == expected, "替身文件要能解析回真实 .app（实际解析到 \(got ?? "nil")）")

        // 普通文件不能被当成替身：否则随便一个 xxx.app 文件都会进列表
        let plain = root.appendingPathComponent("普通.app")
        try? Data("not an app".utf8).write(to: plain)
        check(InstalledApps.resolveAlias(plain) == nil, "普通文件不会被当成替身")

        // 指向非 .app 的替身也不收
        let txt = root.appendingPathComponent("说明.txt")
        try? Data("hi".utf8).write(to: txt)
        let txtAlias = root.appendingPathComponent("说明替身.app")
        if let data = try? txt.bookmarkData() {
            try? data.write(to: txtAlias)
        }
        check(InstalledApps.resolveAlias(txtAlias) == nil, "指向非 app 的替身不被收录")
    }

    /// 应用扫描不能钻进 app 包内部。
    ///
    /// 这是「添加应用」面板转圈 8 秒的根因：剪枝写成"路径超过两层才剪"，
    /// 而 `Foo.app` 这一条深度只有 1 层，于是枚举器走进了每个包的 Contents，
    /// /Applications 一个根就是 40 万条目。剪枝正确时只要十几毫秒。
    /// 断言只钉"结果里不许有嵌套包"，不去断言具体耗时（机器差异太大）。
    /// 静默自回收：验的是**调度行为**，不是"省了多少 MB"。
    ///
    /// 为什么不断言"归还字节数 > 0"：在 macOS 26 上 Darwin 的分配器
    /// free 时就把页还给内核了（实测 free 200MB 之后 footprint 立刻掉 110MB），
    /// 等到我们调 pressure_relief 时它手里已经没有空闲页，返回 0 是**正确结果**。
    /// 把"必须是正数"写成断言，等于强迫实现去造假数据。
    private static func testMemoryReclaim() {
        // 1) 能读到自己的 footprint
        let footprint = MemoryReclaimer.footprintBytes()
        check(footprint > 0, "能读到自身 footprint（\(footprint / 1024 / 1024) MB）")
        check(footprint < 8 * 1024 * 1024 * 1024, "footprint 在合理范围（< 8GB）")

        // 2) 调用本身不能崩、不能返回负值
        let reclaimed = MemoryReclaimer.relieve()
        check(reclaimed >= 0, "relieve 调用安全，本次归还 \(reclaimed) 字节（环境相关）")

        // 3) 防抖：连续结束 5 轮手势，只该留下 1 个待执行任务
        let debounce = MemoryReclaimer()
        debounce.idleDelay = 0.08
        debounce.thresholdBytes = .max          // 关掉"立刻还"那条路，只测静置
        for _ in 0..<5 { debounce.gestureDidFinish() }
        Thread.sleep(forTimeInterval: 0.35)
        check(debounce.idleSweeps == 1,
              "连续 5 轮手势只执行 1 次静置回收（实际 \(debounce.idleSweeps) 次）")

        // 4) 静置期间又来手势 → 重新计时，前一个作废
        let reset = MemoryReclaimer()
        reset.idleDelay = 0.15
        reset.thresholdBytes = .max
        reset.gestureDidFinish()
        Thread.sleep(forTimeInterval: 0.09)     // 还没到点
        check(reset.idleSweeps == 0, "静置未到时不动手（实际 \(reset.idleSweeps) 次）")
        reset.gestureDidFinish()                // 重新计时
        Thread.sleep(forTimeInterval: 0.25)
        check(reset.idleSweeps == 1,
              "被新手势打断后只执行最后那一次（实际 \(reset.idleSweeps) 次）")

        // 5) 阈值路径：footprint 必超 → 立刻归还，不等静置
        let hot = MemoryReclaimer()
        hot.idleDelay = 10
        hot.thresholdBytes = 1
        hot.immediateCooldown = 0
        hot.gestureDidFinish()
        Thread.sleep(forTimeInterval: 0.2)
        check(hot.immediateSweeps == 1,
              "超过阈值立刻归还 1 次（实际 \(hot.immediateSweeps) 次）")

        // 6) 冷却：footprint 一直高也不能每笔都还
        let cooled = MemoryReclaimer()
        cooled.idleDelay = 10
        cooled.thresholdBytes = 1
        cooled.immediateCooldown = 60
        for _ in 0..<4 { cooled.gestureDidFinish() }
        Thread.sleep(forTimeInterval: 0.25)
        check(cooled.immediateSweeps == 1,
              "冷却期内重复触发被压住（4 次手势只还了 \(cooled.immediateSweeps) 次）")
    }

    private static func testAppScanPruning() {
        let start = Date()
        let apps = InstalledApps.scan()
        let cost = Date().timeIntervalSince(start) * 1000

        check(!apps.isEmpty, "扫描能扫出应用（\(apps.count) 个，\(Int(cost)) ms）")

        // 🔴 硬证据：路径里出现 ".app/" 说明这个包是从别的 app 内部捞出来的。
        // 替身解析出来的除外——豆包浏览器本体就在 Doubao.app/Contents/Helpers 里，
        // 用户是往 /Applications 里放了个替身，那条路径含 ".app/" 是正常的。
        let nested = apps.filter { $0.path.contains(".app/") && !$0.viaAlias }
        check(nested.isEmpty, "扫描结果不含嵌套在别的 app 里的包（实际 \(nested.count) 个）")

        check(Set(apps.map(\.bundleID)).count == apps.count, "同一 bundle id 不重复收录")
        let sorted = apps.map(\.name)
        check(sorted == sorted.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
              "结果按名称排序（列表顺序稳定）")

        // 剪枝不该丢应用：每个结果的 bundle id 都得能从路径上认回来
        if let sample = apps.first(where: { !$0.path.contains(".app/") }) {
            check(Bundle(path: sample.path)?.bundleIdentifier == sample.bundleID,
                  "path 与 bundleID 对得上（抽样 \(sample.name)）")
        }
    }

    /// 可用性判断不能再犯「查文件查不到」的错。
    ///
    /// 系统库自 macOS 11 起都在 dyld 共享缓存里，磁盘上没有实体文件。
    /// 上一版用 fileExists 判断，结果一律 false、引擎永远起不来。
    /// 这台机器就是打包机（有内置触控板），所以这里直接断言可用。
    private static func testTrackpadAvailability() {
        check(TrackpadEngine.isAvailable,
              "本机应判定触摸板可用（共享缓存里的框架也算存在）")
    }

    /// 「引擎该跑却没跑」必须能被说出来。
    /// 以前 start() 是静默 return，用户勾了手势只看到"没反应"，一个线索都没有。
    private static func testTrackpadFailureReport() {
        check(TrackpadEngine.failureReport(needed: true, running: false,
                                           reason: "设备初始化失败") == "设备初始化失败",
              "引擎该跑却没跑时要给出原因")
        check(TrackpadEngine.failureReport(needed: true, running: true,
                                           reason: "设备初始化失败") == nil,
              "引擎在跑时不该提示失败")
        check(TrackpadEngine.failureReport(needed: false, running: false,
                                           reason: "设备初始化失败") == nil,
              "用户本来就关掉了引擎，不该弹失败提示")
        check(TrackpadEngine.failureReport(needed: true, running: false,
                                           reason: "") == nil,
              "没有原因就别弹空提示")
    }

    /// 触摸板手势"没反应"有两种断法：没收到帧、收到了没认出来。
    /// 这里用**合成触点**把第二种单独验掉：识别逻辑必须能认出
    /// 三指上滑、两指捏合、单指轻点，而且不该把单指移动当成滑动。
    private static func testTrackpadRecognizer() {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: x, y: y)
        }

        // 三指上滑：y 逐渐增大（触控板坐标朝远端为正）
        var swipeUp: [(fingers: Int, points: [CGPoint])] = []
        for step in 0..<6 {
            let y = 0.30 + Double(step) * 0.05
            swipeUp.append((fingers: 3, points: [point(0.30, y), point(0.50, y), point(0.70, y)]))
        }
        if let report = TrackpadSelfTest.recognize(swipeUp) {
            check(report.event == .swipe(fingers: 3, direction: .up),
                  "三指上滑能被认出来（实际 \(report.event)）")
            check(report.fingers == 3, "三指上滑的手指数是 3（实际 \(report.fingers)）")
        } else {
            check(false, "三指上滑能被认出来")
        }

        // 两指**分先后落板**：第一帧只报 1 根手指，第二帧才 2 根。
        // 真机上这是常态（差 1~2 帧），早先「手指数一变就整轮作废」
        // 让两指滑动永远走不到方向判定——这就是「滑动全都无效」的根因。
        // 起手宽限内必须**重开一轮**并正常识别。
        let staggered: [(fingers: Int, points: [CGPoint])] = [
            (fingers: 1, points: [point(0.80, 0.50)]),
            (fingers: 2, points: [point(0.70, 0.50), point(0.90, 0.50)]),
            (fingers: 2, points: [point(0.65, 0.50), point(0.85, 0.50)]),
            (fingers: 2, points: [point(0.55, 0.50), point(0.75, 0.50)])
        ]
        if let report = TrackpadSelfTest.recognize(staggered) {
            check(report.event == .swipe(fingers: 2, direction: .left),
                  "两指分先后落板仍能认出左滑（实际 \(report.event)）")
        } else {
            check(false, "两指分先后落板仍能认出左滑（实际没认出来）")
        }

        // 但宽限**只**罩住起手那一下。手指按着不动超过 0.15s 之后再补一根，
        // 那是真的换了意图，不能还当同一轮继续判——否则「按住一指再补一指」
        // 会被当成拖拽滑动，误触更糟。
        let lateSecondFinger: [(fingers: Int, points: [CGPoint])] = [
            (fingers: 1, points: [point(0.50, 0.50)]),
            (fingers: 1, points: [point(0.50, 0.50)]),
            (fingers: 1, points: [point(0.50, 0.50)]),
            (fingers: 1, points: [point(0.50, 0.50)]),
            (fingers: 1, points: [point(0.50, 0.50)]),
            (fingers: 2, points: [point(0.40, 0.50), point(0.60, 0.50)])
        ]
        check(TrackpadSelfTest.recognize(lateSecondFinger) == nil,
              "超出起手宽限才补的手指会让整轮作废（不该识别出任何手势）")

        // 手指数在 2↔3 之间来回抖（手掌蹭板边就是这样）：每帧都"在宽限内"、
        // 每帧都重开，startTime 被无限刷新 → 既判不死也走不到判定，
        // 超时收尾还会按「轻点」处理，凭空多出一个「两指轻点」。重开必须封顶。
        let jitter: [(fingers: Int, points: [CGPoint])] = [
            (fingers: 2, points: [point(0.40, 0.50), point(0.60, 0.50)]),
            (fingers: 3, points: [point(0.40, 0.50), point(0.60, 0.50), point(0.50, 0.62)]),
            (fingers: 2, points: [point(0.40, 0.50), point(0.60, 0.50)]),
            (fingers: 3, points: [point(0.40, 0.50), point(0.60, 0.50), point(0.50, 0.62)]),
            (fingers: 2, points: [point(0.40, 0.50), point(0.60, 0.50)]),
            (fingers: 3, points: [point(0.40, 0.50), point(0.60, 0.50), point(0.50, 0.62)])
        ]
        check(TrackpadSelfTest.recognize(jitter) == nil,
              "手指数来回抖动不会变成凭空一次轻点（实际 \(String(describing: TrackpadSelfTest.recognize(jitter)?.event))）")


        // 早先同样整轮作废，用户看到的是「划线基本识别不了」。
        var pathWithNoise: [(fingers: Int, points: [CGPoint])] = []
        for step in 0..<12 {
            pathWithNoise.append((fingers: 1,
                                  points: [point(0.15 + Double(step) * 0.06, 0.50)]))
        }
        // 第 3 帧（起手宽限内）多报一个触点，下一帧又消失
        pathWithNoise.insert((fingers: 2,
                              points: [point(0.27, 0.50), point(0.31, 0.62)]), at: 2)
        let noisyPath = TrackpadSelfTest.recognize(pathWithNoise)
        check({
            if case .path = noisyPath?.event { return true }
            return false
        }(), "起手后中途多报一个触点，画轨迹仍能识别（实际 \(String(describing: noisyPath?.event))）")


        var pinch: [(fingers: Int, points: [CGPoint])] = []
        for step in 0..<6 {
            let half = 0.20 - Double(step) * 0.03
            pinch.append((fingers: 2, points: [point(0.5 - half, 0.5), point(0.5 + half, 0.5)]))
        }
        if let report = TrackpadSelfTest.recognize(pinch) {
            if case let .pinch(ratio) = report.event {
                check(ratio < 1, "两指捏合的方向是合拢（比例 \(String(format: "%.2f", ratio))）")
            } else {
                check(false, "两指捏合能被认出来（实际 \(report.event)）")
            }
        } else {
            check(false, "两指捏合能被认出来")
        }

        // 单指轻点：几乎没动，抬手后应该判成轻点
        let tap: [(fingers: Int, points: [CGPoint])] = [
            (fingers: 1, points: [point(0.5, 0.5)]),
            (fingers: 1, points: [point(0.5, 0.5)])
        ]
        if let report = TrackpadSelfTest.recognize(tap) {
            check(report.event == .tap(fingers: 1),
                  "单指轻点能被认出来（实际 \(report.event)）")
        } else {
            check(false, "单指轻点能被认出来")
        }

        // 单指移动**不能**判成滑动：单指在触控板上就是移动指针，判成手势会一路误触。
        // 大幅移动会被识别成「画轨迹」（1.0.12 新形态），但绝不能是滑动。
        var singleMove: [(fingers: Int, points: [CGPoint])] = []
        for step in 0..<6 {
            singleMove.append((fingers: 1, points: [point(0.2 + Double(step) * 0.1, 0.5)]))
        }
        let singleResult = TrackpadSelfTest.recognize(singleMove)
        check(singleResult == nil || {
            switch singleResult!.event {
            case .tap, .path: return true
            default:          return false
            }
        }(), "单指移动不会被误判成滑动（实际 \(String(describing: singleResult?.event))）")

        // 修饰键要跟着走：起手那帧按着 Fn，报告里就得带 Fn
        let withModifier = TrackpadSelfTest.recognize(tap, modifiers: [.fn])
        check(withModifier?.modifiers == [.fn],
              "起手帧的修饰键会跟着识别结果一起带出来（实际 \(String(describing: withModifier?.modifiers))）")
    }

    /// 触摸板手势最容易坏的地方：修饰键。
    ///
    /// 规则是「起手判一次 + 全等匹配」——手指落下那一刻读到什么修饰键，
    /// 这一轮就用什么；候选的修饰键必须**完全一样**才命中。
    /// 任何一个环节对不上，用户看到的就是「触摸板操作无效」。
    /// 右键单击重放的死循环修复（1.0.12）。
    ///
    /// 短点击会被重放成一次普通点击；重放事件必须被自己的 tap **放行**，
    /// 否则就是：吞 → 重放 → 再吞 → 再重放……点右键红点狂闪、鼠标卡死。
    /// 修复手段是给重放事件打 `eventSourceUserData` 标记，回调里见标记就放行。
    private static func testReplayMarkPassthrough() {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxmouse-replay-\(UUID().uuidString)")
        let store = GestureStore(directory: temp)
        // 出厂手势保证右键候选非空——这样「放行」才是标记的功劳，不是候选空的功劳
        let rightCandidates = store.candidates(trigger: .rightButton, modifiers: [], bundleID: "com.apple.Safari")
        check(!rightCandidates.isEmpty, "出厂手势里有右键手势（重放测试的前提）")

        let engine = GestureEngine(store: store)

        // ① 带标记的右键按下：必须原样放行，且不进入手势状态
        let marked = CGEvent(mouseEventSource: nil,
                             mouseType: .rightMouseDown,
                             mouseCursorPosition: CGPoint(x: 640, y: 400),
                             mouseButton: .right)!
        marked.setIntegerValueField(.eventSourceUserData, value: GestureEngine.replayMark)
        let markedResult = engine.handle(type: .rightMouseDown, event: marked)
        check(markedResult != nil
              && markedResult!.toOpaque() == Unmanaged.passUnretained(marked).toOpaque(),
              "带重放标记的右键按下会原样放行（返回同一个事件）")

        // ② 不带标记的同一次按下：候选非空，应照常被吞掉进入手势状态
        let plain = CGEvent(mouseEventSource: nil,
                            mouseType: .rightMouseDown,
                            mouseCursorPosition: CGPoint(x: 640, y: 400),
                            mouseButton: .right)!
        let plainResult = engine.handle(type: .rightMouseDown, event: plain)
        check(plainResult == nil, "不带标记的右键按下照常被吞（进入手势状态）")

        engine.stop()
        try? FileManager.default.removeItem(at: temp)
    }

    private static func testTrackpadModifierMatching() {
        let tap: [(fingers: Int, points: [CGPoint])] = [
            (fingers: 1, points: [CGPoint(x: 0.5, y: 0.5)]),
            (fingers: 1, points: [CGPoint(x: 0.5, y: 0.5)])
        ]

        // ① 起手时按着 Fn，后面松开 → 整轮仍然算 Fn
        let drifted = TrackpadSelfTest.recognize(tap, modifiersPerFrame: [[.fn], [], []])
        check(drifted?.modifiers == [.fn],
              "起手之后松开修饰键，这一轮仍按起手时的算（实际 \(String(describing: drifted?.modifiers))）")

        // ② 起手时什么都没按，**0.2 秒内**补按 Fn → 采纳。
        //    人做不到把修饰键按在手指落下之前那一帧上，早先的「只在起手帧判一次」
        //    等于要求用户先按住修饰键再落指、且不能差一帧，实际用起来就是"配了没用"。
        let early: [(fingers: Int, points: [CGPoint])] = Array(
            repeating: (fingers: 1, points: [CGPoint(x: 0.5, y: 0.5)]), count: 6)
        let late = TrackpadSelfTest.recognize(
            early, modifiersPerFrame: [[], [], [.fn], [.fn], [.fn], [.fn]])
        check(late?.modifiers == [.fn],
              "起手 0.2 秒内补按的修饰键会采纳（实际 \(String(describing: late?.modifiers))）")

        // ③ 但起手 0.2 秒**之后**才按的仍然不采纳：那一轮早就在按别的意图判了
        let tooLate = TrackpadSelfTest.recognize(
            early, modifiersPerFrame: [[], [], [], [], [], [.fn]])
        check(tooLate?.modifiers == [],
              "起手 0.2 秒之后才按的修饰键不参与匹配（实际 \(String(describing: tooLate?.modifiers))）")

        // ③ 候选筛选：全等匹配
        // 用临时目录建一个干净的库，塞两条形态完全相同、只有修饰键不同的手势。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoxMouseSelfTest-\(UUID().uuidString)")
        let store = GestureStore(directory: dir)
        let scope = store.globalScope
        let plain = Gesture(name: "无修饰三指上滑",
                            kind: .trackpad,
                            modifiers: [],
                            trackpad: .swipe(fingers: 3, .up),
                            action: .window(.minimize),
                            scopeID: scope.id)
        let withFn = Gesture(name: "带 Fn 三指上滑",
                             kind: .trackpad,
                             modifiers: [.fn],
                             trackpad: .swipe(fingers: 3, .up),
                             action: .window(.minimize),
                             scopeID: scope.id)
        store.add(plain)
        store.add(withFn)

        let event = TrackpadEvent.swipe(fingers: 3, direction: .up)

        let noMod = store.trackpadCandidates(event: event, modifiers: [], bundleID: nil)
        check(noMod.count == 1 && noMod.first?.name == plain.name,
              "没按修饰键时只命中无修饰的那条（命中 \(noMod.map(\.name))）")

        let fnMod = store.trackpadCandidates(event: event, modifiers: [.fn], bundleID: nil)
        check(fnMod.count == 1 && fnMod.first?.name == withFn.name,
              "按住 Fn 时只命中带 Fn 的那条（命中 \(fnMod.map(\.name))）")

        // 修饰键读不出来（配了 Fn 但系统没报上来）时，带 Fn 的那条不该被误命中，
        // 但无修饰的那条应该能命中——这正是用户看到的"配了 Fn 就全都不灵"
        let readFail = store.trackpadCandidates(event: event, modifiers: [], bundleID: nil)
        check(readFail.contains { $0.name == plain.name } && !readFail.contains { $0.name == withFn.name },
              "修饰键读不出来时不会误命中带 Fn 的手势")

        // 修饰键多一个也不行：全等，不是包含
        let extra = store.trackpadCandidates(event: event, modifiers: [.fn, .command], bundleID: nil)
        check(extra.isEmpty,
              "多按了一个修饰键就不命中（命中 \(extra.map(\.name))）")

        try? FileManager.default.removeItem(at: dir)
    }
}
