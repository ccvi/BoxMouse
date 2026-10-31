import Foundation

// ============================================================
// 诊断：手势库里哪些模板互相像到会打架
//
//   .build/debug/BoxMouse --pathdiff [阈值，默认 0.70]
//
// 为什么需要这个工具：两条模板形状相近又同时启用时，画一笔两条都能过阈值，
// 命中谁取决于毫秒级的抖动——用户感受是"这条手势识别不准"，
// 但列表里那张 60×36 的缩略图根本看不出两条有多像，只能把分数打出来。
//
// 冲突对里额外打印「反向得分」：如果正着画和反着画的分数几乎一样，
// 说明算法没在看起笔方向（DTW 是对称的），一对镜像手势必然互相抢。
// ============================================================

@MainActor
enum PathDiffProbe {

    /// 按名字查一条手势：与全库的分数排行 + 手绘变体的命中率。
    ///
    ///   BoxMouse --pathdiff 还原
    static func runOne(_ name: String) {
        let store = GestureStore()
        guard let target = store.gestures.first(where: { $0.name == name && $0.path.count > 1 }) else {
            print("没有找到名字为「\(name)」且带轨迹的手势")
            let names = store.gestures.filter { !$0.path.isEmpty }.map(\.name)
            print("可选：" + names.joined(separator: "、"))
            return
        }

        print("「\(target.name)」 走向 \(PathRecognizer.directionString(target.path))  "
              + String(format: "首(%.2f,%.2f) 末(%.2f,%.2f)",
                       target.path.first!.x, target.path.first!.y,
                       target.path.last!.x, target.path.last!.y))
        print("识别阈值 \(String(format: "%.2f", PathRecognizer.matchThreshold))")
        print("────────────────────────────────────────")

        // 1) 与全库的分数排行：看有没有"差一点就抢走"的邻居
        var ranked: [(String, Double)] = []
        for other in store.gestures where other.path.count == target.path.count {
            let value = PathRecognizer.score(target.path, other.path)
            ranked.append(("\(other.name)\(other.enabled ? "" : "(停用)")", value))
        }
        ranked.sort { $0.1 > $1.1 }
        print("与全库最像的 5 条：")
        for entry in ranked.prefix(5) {
            print(String(format: "  %.3f  %@", entry.1, entry.0))
        }

        // 2) 手绘变体：把模板做各种"人画歪了"的变形，看还能不能认出自己。
        //    斜线手势最容易出问题——人手画 40° 的线，实际可能是 25° 也可能是 55°。
        print("────────────────────────────────────────")
        print("手绘变体（重新归一化后再自比）：")
        for variant in variants(of: target.path) {
            let normalized = PathRecognizer.normalize(variant.points)
            let detail = PathRecognizer.breakdown(normalized, target.path)
            let hit = detail.total >= PathRecognizer.matchThreshold
            print(String(format: "  %.3f  %@  %-16@ [%@ dtw %.2f 角 %.2f 直线 %.2f]",
                         detail.total,
                         hit ? "✓" : "✗ 认不出",
                         variant.label as NSString,
                         detail.route as NSString,
                         detail.dtw,
                         detail.angle,
                         detail.straight))
        }
    }

    /// 一组模拟手绘偏差的变形
    private static func variants(of path: [PathPoint]) -> [(label: String, points: [CGPoint])] {
        let base = path.map { CGPoint(x: $0.x, y: $0.y) }

        func transformed(rotate degrees: Double = 0,
                         scaleX: Double = 1,
                         scaleY: Double = 1) -> [CGPoint] {
            let radians = degrees * .pi / 180
            return base.map { point in
                let x = point.x * scaleX
                let y = point.y * scaleY
                return CGPoint(x: x * cos(radians) - y * sin(radians),
                               y: x * sin(radians) + y * cos(radians))
            }
        }

        // 起笔多画一小段：真实手绘起笔常带一点方向偏移
        var hook = base
        let first = base[0]
        let second = base[1]
        hook.insert(CGPoint(x: first.x - (second.x - first.x) * 1.2,
                            y: first.y - (second.y - first.y) * 1.2), at: 0)

        /// 把直线弯成弧：中段垂直于弦偏移 bulge（相对弦长的比例）。
        /// 人画斜线最容易画弯——手腕绕肘部转，走的是弧不是直线。
        func arced(bulge: Double) -> [CGPoint] {
            guard let start = base.first, let end = base.last else { return base }
            let dx = end.x - start.x
            let dy = end.y - start.y
            let chord = hypot(dx, dy)
            guard chord > 0.001 else { return base }
            let nx = -dy / chord
            let ny = dx / chord
            let count = base.count
            return base.enumerated().map { index, point in
                let t = Double(index) / Double(max(1, count - 1))
                let offset = bulge * sin(.pi * t)
                return CGPoint(x: point.x + nx * offset, y: point.y + ny * offset)
            }
        }

        let chordLength = hypot(base.last!.x - base.first!.x, base.last!.y - base.first!.y)

        return [
            ("原样", base),
            ("更平（横轴 ×1.15）", transformed(scaleX: 1.15)),
            ("更陡（纵轴 ×1.15）", transformed(scaleY: 1.15)),
            ("走向偏 7°", transformed(rotate: 7)),
            ("走向偏 −7°", transformed(rotate: -7)),
            ("走向偏 12°", transformed(rotate: 12)),
            ("走向偏 −12°", transformed(rotate: -12)),
            ("走向偏 15°", transformed(rotate: 15)),
            ("走向偏 −15°", transformed(rotate: -15)),
            ("走向偏 20°", transformed(rotate: 20)),
            ("走向偏 −20°", transformed(rotate: -20)),
            ("走向偏 25°", transformed(rotate: 25)),
            ("走向偏 −25°", transformed(rotate: -25)),
            ("走向偏 30°", transformed(rotate: 30)),
            ("走向偏 −30°", transformed(rotate: -30)),
            ("起笔带小勾", hook),
            ("轻微弧形（弯 6%）", arced(bulge: chordLength * 0.06)),
            ("明显弧形（弯 12%）", arced(bulge: chordLength * 0.12)),
            ("很弯（20%）", arced(bulge: chordLength * 0.20))
        ]
    }

    static func run(threshold: Double = 0.70) {
        let store = GestureStore()
        let all = store.gestures
        let mouse = all.filter { $0.kind == .mouse && $0.path.count > 1 }

        print("手势库共 \(all.count) 条，其中鼠标手势 \(mouse.count) 条")
        print("冲突阈值 \(String(format: "%.2f", threshold))（识别阈值 \(String(format: "%.2f", PathRecognizer.matchThreshold))）")
        print("────────────────────────────────────────")

        // 🔴 必须按作用域分组：应用专属手势和全局手势不会互相抢。
        // 候选里应用级排在全局前面、bestMatch 用严格大于取最高分，
        // 所以同一笔在应用里优先走应用那条 —— 这是设计好的优先关系，不是冲突。
        // 早先这一版是全库两两比对，把「Safari 里的横线」和「全局的横线」报成冲突，
        // 全是假警报。
        let groups = Dictionary(grouping: mouse, by: \.scopeID)

        func label(_ scopeID: UUID) -> String {
            let name = store.scopeName(id: scopeID)
            let kind = store.scope(id: scopeID)?.kind == .global ? "全局" : "应用"
            return "\(kind)·\(name)"
        }

        var conflicts: Int = 0
        for (scopeID, items) in groups.sorted(by: { label($0.key) < label($1.key) }) {
            guard items.count > 1 else { continue }
            print("【\(label(scopeID))】 \(items.count) 条")

            var groupConflicts = 0
            for i in items.indices {
                for j in items.indices where j > i {
                    let a = items[i]
                    let b = items[j]
                    let forward = PathRecognizer.score(a.path, b.path)
                    guard forward >= threshold else { continue }
                    groupConflicts += 1
                    conflicts += 1

                    let backward = PathRecognizer.score(a.path, Array(b.path.reversed()))
                    print(String(format: "  %.3f  %@「%@」 × %@「%@」%@",
                                 forward,
                                 a.enabled ? "" : "(停用) ",
                                 a.name,
                                 b.enabled ? "" : "(停用) ",
                                 b.name,
                                 a.enabled && b.enabled ? "   ← 两条都启用，会互相抢" : ""))
                    print(String(format: "         反向得分 %.3f  → %@",
                                 backward,
                                 backward >= forward - 0.02
                                    ? "方向几乎不影响打分（起笔方向没参与判定）"
                                    : "方向有影响"))
                }
            }
            if groupConflicts == 0 {
                print("  无冲突")
            }
        }

        print("────────────────────────────────────────")
        if conflicts == 0 {
            print("同一作用域内没有互为干扰的手势")
        } else {
            print("同一作用域内共 \(conflicts) 对互为干扰")
        }

        // 逐条自比：模板与自己的分数必然是满分，用来确认数据本身没坏
        print("────────────────────────────────────────")
        for gesture in mouse {
            let selfScore = PathRecognizer.score(gesture.path, gesture.path)
            let body = PathRecognizer.directionString(gesture.path)
            // 直线度：真实手画到底弯多少。斜线最容易画弯，这是"认不出"的常见原因
            let bend = maxBendPercent(gesture.path)
            let tag = bend < 8 ? "直" : (bend < 14 ? "微弯" : "弯")
            print(String(format: "%.2f 自比  %@「%@」  走向 %@  弯曲 %.1f%%（%@）",
                         selfScore,
                         gesture.enabled ? "" : "(停用) ",
                         gesture.name,
                         body,
                         bend,
                         tag))
        }
    }

    /// 中段相对端点连线的最大垂直偏离，按弦长百分比算
    static func maxBendPercent(_ path: [PathPoint]) -> Double {
        guard let start = path.first, let end = path.last, path.count > 2 else { return 0 }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let chord = hypot(dx, dy)
        guard chord > 0.001 else { return 0 }
        var worst: Double = 0
        for point in path {
            // 点到直线的距离 = |叉积| / 弦长
            let cross = (point.x - start.x) * dy - (point.y - start.y) * dx
            worst = max(worst, abs(cross) / chord)
        }
        return worst / chord * 100
    }
}
