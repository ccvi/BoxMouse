import Foundation
import CoreGraphics

// ============================================================
// 自由轨迹识别
//
// 归一化：重采样 → 重心居中 → **等比缩放**（除以最长轴）。
// 🔴 1.0.12 之前是「按轴各自缩放 + 短轴死区」——那是为逐点距离服务的；
//    但按轴缩放会**破坏角度**（16° 的横线被短轴下限放大成 39°），
//    折线（闪电 / Z 形）的方向证据整个失真，用户要画好几次才命中。
//    现在打分的两路证据（DTW 对齐距离、RDP 段角度）都天然容忍臂长比例，
//    按轴缩放不再必要，等比缩放让角度完全保真。
//
// 打分 = max(五路尝试)，前四路每一路 = 0.62×DTW + 0.38×段角度：
//   ① 原始轨迹
//   ② 双方按「整体走向」压掉短轴（横线/竖线的手抖双方各自压平，见 flatByDirection）
//   ③ 双方裁掉首尾各 8%（起笔/收笔的小勾）
//   ④ ② + ③
//   ⑤ 两条都是**直线**（贴着首尾连线）时直接比走向角，二次衰减
//   取最高分——多尝试只放宽「同一形状的不同画法」，不放宽不同形状（实验负例最高 0.63）。
//
// ⑤ 是 1.0.23 加的：斜线画得不够角度（模板 41°、实际 25°）以前会认不出。
//   直线型形状的信息只剩走向，所以这一路按角度差衰减，27° 左右落到阈值下，
//   同行最近的另一条直线差 41°，仍有 14° 余量；折线进不了这一路。
//
// 仍然**不做旋转不变**：手势有方向，"向上画一道"和"向右画一道"必须区分开。
// 幅度不变、速度不变、起点无关——这三条是手势库能跨人跨次复用的前提。
// ============================================================

enum PathRecognizer {

    /// 重采样点数。32 足够描述常见手势，再多只是增加比对成本。
    static let sampleCount = 32

    /// 匹配阈值。实验校准（25 个手绘变体 vs 6 类形状两两比对）：
    /// 正例最差 0.794、负例最高 0.629 —— 0.78 在两者之间留有双向余量。
    static let matchThreshold: Double = 0.78

    // MARK: - 基础几何

    /// 轨迹总长度（像素）
    static func length(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for index in 1..<points.count {
            total += hypot(points[index].x - points[index - 1].x,
                           points[index].y - points[index - 1].y)
        }
        return total
    }

    /// 按弧长等距重采样
    static func resample(_ points: [CGPoint], to count: Int = sampleCount) -> [CGPoint] {
        guard points.count > 1 else { return points }
        let total = length(points)
        // 退化情况（所有点重合）直接返回原位，否则下面除零
        guard total > 0.0001 else { return Array(repeating: points[0], count: count) }

        let interval = total / CGFloat(count - 1)
        var resampled: [CGPoint] = [points[0]]
        var accumulated: CGFloat = 0
        var previous = points[0]

        for index in 1..<points.count {
            let current = points[index]
            let segment = hypot(current.x - previous.x, current.y - previous.y)
            if accumulated + segment >= interval {
                let ratio = (interval - accumulated) / segment
                let interpolated = CGPoint(x: previous.x + (current.x - previous.x) * ratio,
                                           y: previous.y + (current.y - previous.y) * ratio)
                resampled.append(interpolated)
                previous = interpolated
                accumulated = 0
                // 一段可能覆盖多个采样点
                while resampled.count < count {
                    let remaining = hypot(current.x - previous.x, current.y - previous.y)
                    if remaining < interval { break }
                    let r = interval / remaining
                    let next = CGPoint(x: previous.x + (current.x - previous.x) * r,
                                       y: previous.y + (current.y - previous.y) * r)
                    resampled.append(next)
                    previous = next
                }
            } else {
                accumulated += segment
                previous = current
            }
        }

        // 补齐（浮点误差导致少一两个点）
        while resampled.count < count {
            resampled.append(points[points.count - 1])
        }
        return Array(resampled.prefix(count))
    }

    /// 归一化：重采样 → 重心居中 → **等比**缩放到最长轴 [-1,1]
    ///
    /// 🔴 必须等比：DTW 与段角度都直接读角度/距离，按轴缩放会把 16° 的斜线
    /// 放大成 39°（短轴被轴下限抬高再归一），折线的方向证据整个失真。
    /// 短轴上的手抖不再在这里处理——匹配时的 `flatByDirection` 按「整体走向」
    /// 对称压轴，比按幅度比例压更符合语义，也不会出现"模板压平了、输入没压平"的不对称。
    static func normalize(_ points: [CGPoint], count: Int = sampleCount) -> [PathPoint] {
        let resampled = resample(points, to: count)
        guard !resampled.isEmpty else { return [] }

        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for point in resampled {
            sumX += point.x
            sumY += point.y
        }
        let centerX = sumX / CGFloat(resampled.count)
        let centerY = sumY / CGFloat(resampled.count)

        var extentX: CGFloat = 0
        var extentY: CGFloat = 0
        for point in resampled {
            extentX = max(extentX, abs(point.x - centerX))
            extentY = max(extentY, abs(point.y - centerY))
        }
        let scale = max(extentX, extentY)
        guard scale > 0.0001 else { return resampled.map { _ in PathPoint(x: 0, y: 0) } }

        return resampled.map {
            PathPoint(x: Double(($0.x - centerX) / scale),
                      y: Double(($0.y - centerY) / scale))
        }
    }

    // MARK: - 显示辅助

    /// 显示层的直线修正（**只用于显示，识别数据不动**）。
    ///
    /// 等比归一化保真之后，一条横线的 y 可能还留着 ±5% 的真实手抖；
    /// 缩略图和录入框是按轴各自铺满的，±5% 会被放大成肉眼可见的锯齿，
    /// 用户会以为手势画歪了。短轴幅度低于阈值就整轴置中——
    /// 只压"看起来就是直线"的轨迹（另一轴明显更长），斜线和折线不动。
    static func displayStraighten(_ path: [PathPoint], threshold: Double = 0.15) -> [PathPoint] {
        guard path.count > 1 else { return path }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for point in path {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let extentX = maxX - minX
        let extentY = maxY - minY
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2
        let flattenY = extentY < threshold && extentX >= extentY
        let flattenX = extentX < threshold && extentY > extentX
        guard flattenX || flattenY else { return path }
        return path.map {
            PathPoint(x: flattenX ? centerX : $0.x, y: flattenY ? centerY : $0.y)
        }
    }

    // MARK: - 打分

    /// 两条**已归一化**轨迹的相似度，0…1。
    /// 五路尝试取最高（见文件头注释），前四路 = 0.62×DTW + 0.38×段角度，
    /// 第五路是「两条都是直线时直接比走向」。
    static func score(_ a: [PathPoint], _ b: [PathPoint]) -> Double {
        breakdown(a, b).total
    }

    /// 各路尝试的拆解，诊断工具用（--pathdiff 把输赢哪一路打出来）
    struct Breakdown {
        var total: Double = 0
        var route: String = "-"
        var dtw: Double = 0
        var angle: Double = 0
        var straight: Double = 0
    }

    static func breakdown(_ a: [PathPoint], _ b: [PathPoint]) -> Breakdown {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return Breakdown() }

        let flatA = flatByDirection(a)
        let flatB = flatByDirection(b)
        let trimA = trimEnds(a)
        let trimB = trimEnds(b)

        let routes: [(String, [PathPoint], [PathPoint])] = [
            ("原始", a, b),
            ("压平", flatA, flatB),
            ("裁首尾", trimA, trimB),
            ("压平+裁首尾", flatByDirection(trimA), flatByDirection(trimB))
        ]

        var result = Breakdown(straight: straightScore(a, b))
        for (name, left, right) in routes {
            let dtw = dtwScore(left, right)
            let angle = segmentAngleSimilarity(left, right)
            let value = 0.62 * dtw + 0.38 * angle
            if value > result.total {
                result.total = value
                result.route = name
                result.dtw = dtw
                result.angle = angle
            }
        }
        if result.straight > result.total {
            result.total = result.straight
            result.route = "直线走向"
        }
        return result
    }

    // MARK: - 直线走向（第五路）

    /// 一条轨迹的**走向角**（度，屏幕坐标 y 向下），前提是它确实是一条直线：
    /// 整条轨迹都贴着自己的首尾连线（最大垂直偏离 ≤ 15% 弦长）。
    /// 打圈的、明显折的、拱形的都返回 nil —— 那些交给前四路。
    ///
    /// 🔴 偏离必须按**弦长比例**判，不能拍一个绝对值：轨迹是归一化过的，
    /// 一条长斜线的弦有 2.5，5% 的手弯就是 0.13，绝对值 0.15 卡在边界上，
    /// 「还原」勉强算直线、「最小化」就差一点不算——同一对镜像手势一个认得出
    /// 一个认不出，而它们的弯曲程度其实一样。
    private static func straightChordAngle(_ path: [PathPoint]) -> Double? {
        guard let start = path.first, let end = path.last, path.count > 2 else { return nil }
        let dx = end.x - start.x
        let dy = end.y - start.y
        let baseline = hypot(dx, dy)
        // 位移太小说明是个点/小圈，走向没有意义
        guard baseline >= 0.5 else { return nil }
        for point in path {
            let deviation = abs((point.x - start.x) * dy - (point.y - start.y) * dx) / baseline
            if deviation > 0.15 * baseline { return nil }
        }
        return atan2(dy, dx) * 180 / .pi
    }

    /// 两条直线型轨迹的相似度：只看走向角差，二次衰减到 0。
    ///
    /// 🔴 为什么需要这一路：斜线手势最典型的失败不是"画错形状"，而是
    /// **"画得不够角度"**——模板 41° 的斜线，手一抖只画出 25°。
    /// 前四路对纯旋转极其敏感：两条直线在中点交叉，逐点距离按长度放大，
    /// DTW 掉得比段角度快得多（实测偏 25° 只剩 0.70 上下，刚好卡在阈值下面）。
    /// 而直线型形状的信息**只有走向**——长度、粗细、位置都被归一化抹掉了。
    ///
    /// 所以这一路既充分又不会放宽到别的形状：
    /// 全库最近的另一条直线（全局的"还原"41° 和"右半屏"0°）差 41°，
    /// 衰减曲线在 27° 落到阈值，中间留 14° 余量；
    /// 折线（刷新 / 恢复标签页 / 关闭窗口）直线度不达标，根本进不了这一路。
    private static func straightScore(_ a: [PathPoint], _ b: [PathPoint]) -> Double {
        guard let angleA = straightChordAngle(a),
              let angleB = straightChordAngle(b) else { return 0 }
        var delta = abs(angleA - angleB).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta = 360 - delta }
        let limit = 55.0
        guard delta < limit else { return 0 }
        let ratio = delta / limit
        return 1 - ratio * ratio
    }

    // MARK: - DTW 对齐距离

    /// 动态时间规整距离（归一化到路径长度）。
    ///
    /// 固定对齐的逐点距离对「转角落在哪个采样序号」极敏感——折线的两个转角
    /// 漂移两三个序号，误差就翻倍。DTW 允许非线性对齐，角点漂移几乎不扣分。
    /// 实验：正例（含臂长 2.5 倍变化、转角漂移 15%）DTW 距离 ≤ 0.083；
    /// 不同形状之间 ≥ 0.099。分母 0.30 让两群分开落在 0.72+ 与 0.67- 两侧。
    private static func dtwScore(_ a: [PathPoint], _ b: [PathPoint]) -> Double {
        let count = a.count
        guard count == b.count, count > 0 else { return 0 }

        var previous = [Double](repeating: .infinity, count: count + 1)
        var current = [Double](repeating: .infinity, count: count + 1)
        previous[0] = 0
        for i in 1...count {
            current[0] = .infinity
            for j in 1...count {
                let dx = a[i - 1].x - b[j - 1].x
                let dy = a[i - 1].y - b[j - 1].y
                let step = hypot(dx, dy)
                current[j] = step + min(previous[j], current[j - 1], previous[j - 1])
            }
            swap(&previous, &current)
        }
        let normalized = previous[count] / Double(count * 2)
        return max(0, min(1, 1 - normalized / 0.30))
    }

    // MARK: - RDP 段角度

    /// Ramer–Douglas–Peucker 折线简化：把手绘的抖动去掉，只留真正的转折点。
    /// 闪电形无论臂长怎么画，简化后都是同样的三段 → 段角度序列稳定。
    private static func rdpSimplify(_ path: [PathPoint], epsilon: Double = 0.15) -> [PathPoint] {
        guard path.count >= 3 else { return path }

        func perpendicularDistance(_ p: PathPoint, from a: PathPoint, to b: PathPoint) -> Double {
            let abx = b.x - a.x, aby = b.y - a.y
            let length = hypot(abx, aby)
            if length < 1e-9 {
                return hypot(p.x - a.x, p.y - a.y)
            }
            return abs((p.x - a.x) * aby - (p.y - a.y) * abx) / length
        }

        var maxDistance = 0.0
        var splitIndex = 0
        for index in 1..<(path.count - 1) {
            let distance = perpendicularDistance(path[index], from: path[0], to: path[path.count - 1])
            if distance > maxDistance {
                maxDistance = distance
                splitIndex = index
            }
        }
        if maxDistance > epsilon {
            let left = rdpSimplify(Array(path[0...splitIndex]), epsilon: epsilon)
            let right = rdpSimplify(Array(path[splitIndex...]), epsilon: epsilon)
            return left.dropLast() + right
        }
        return [path[0], path[path.count - 1]]
    }

    /// 每一段直线的主方向角（度）。段位移太小（<0.08）的丢弃——那是残余抖动。
    private static func segmentAngles(_ path: [PathPoint]) -> [Double] {
        let kept = rdpSimplify(path)
        guard kept.count >= 2 else { return [] }
        var angles: [Double] = []
        for index in 1..<kept.count {
            let dx = kept[index].x - kept[index - 1].x
            let dy = kept[index].y - kept[index - 1].y
            if hypot(dx, dy) > 0.08 {
                angles.append(atan2(dy, dx) * 180 / .pi)
            }
        }
        return angles
    }

    /// 段角度序列的相似度（0…1）。
    ///
    /// 用**连续角度差**而不是 8 方位量化：量化在 22.5° 边界两侧会把差 7° 的两个
    /// 方向判成不同字符，编辑距离一整分的重罚全花在边界抖动上。
    /// 两形状段数不同时做 DP 对齐：配对成本 = 角度差/90（反向 = 2 分封顶），
    /// 删段成本 = 1。平均惩罚归一化到 0…1。
    private static func segmentAngleSimilarity(_ a: [PathPoint], _ b: [PathPoint]) -> Double {
        let anglesA = segmentAngles(a)
        let anglesB = segmentAngles(b)
        guard !anglesA.isEmpty, !anglesB.isEmpty else { return 0 }

        let n = anglesA.count, m = anglesB.count

        func pairingCost(_ x: Double, _ y: Double) -> Double {
            var difference = abs(x - y).truncatingRemainder(dividingBy: 360)
            if difference > 180 { difference = 360 - difference }
            return min(2.0, difference / 90)
        }

        var previous = (0...m).map { Double($0) }
        var current = [Double](repeating: 0, count: m + 1)
        for i in 1...n {
            current[0] = Double(i)
            for j in 1...m {
                current[j] = min(previous[j] + 1,                      // 删 A 的一段
                                 current[j - 1] + 1,                   // 删 B 的一段
                                 previous[j - 1] + pairingCost(anglesA[i - 1], anglesB[j - 1]))
            }
            swap(&previous, &current)
        }
        let penalty = previous[m] / Double(max(n, m))
        return max(0, 1 - penalty)
    }

    // MARK: - 多尝试的两个变体

    /// 按「整体走向」压掉短轴：起点→终点向量接近水平（±18°）就清零 y，
    /// 接近垂直就清零 x；斜向或闭合（位移 < 0.3）不动。
    ///
    /// 🔴 直线类手势最大的不稳定来源：模板 y 抖 7°、输入抖 16°，按幅度比例判断
    /// 会一个压平一个不压平，形状对比直接崩。按走向判断双方对称：
    /// 只要都"基本是横线"，就都压成水平直线再比。
    /// 走向读的是**等比归一化后**的坐标——等比不破坏角度，判断是准的。
    ///
    /// 🔴 还必须先验「直线度」：拱形/弧线的首尾向量也可能是水平的（两端同高），
    /// 不检查就把整条拱压成一条水平线，弧线和直线就再也分不开了
    /// （实验里直线 vs 弧线因此飙到 0.985）。只有整条轨迹贴着首尾连线
    /// （最大垂直距离 ≤ 0.12）才允许压平。
    private static func flatByDirection(_ path: [PathPoint],
                                        tolerance: Double = 18,
                                        straightTolerance: Double = 0.12) -> [PathPoint] {
        guard path.count > 1 else { return path }
        let dx = path[path.count - 1].x - path[0].x
        let dy = path[path.count - 1].y - path[0].y
        guard hypot(dx, dy) >= 0.3 else { return path }

        let baseline = hypot(dx, dy)
        for point in path {
            let deviation = abs((point.x - path[0].x) * dy - (point.y - path[0].y) * dx) / baseline
            if deviation > straightTolerance { return path }
        }

        let angle = atan2(dy, dx) * 180 / .pi
        // 0 = 水平，90 = 垂直（折叠到 0…90）
        var axis = abs((angle + 90).truncatingRemainder(dividingBy: 180) - 90)
        if axis > 90 { axis = 180 - axis }
        if axis <= tolerance {
            return path.map { PathPoint(x: $0.x, y: 0) }
        }
        if axis >= 90 - tolerance {
            return path.map { PathPoint(x: 0, y: $0.y) }
        }
        return path
    }

    /// 裁掉首尾各 8%：起笔的顿笔、收笔的甩尾是手绘最常见的小勾，
    /// 对形状本身没有信息量，却会把重心和首尾点带偏。
    private static func trimEnds(_ path: [PathPoint]) -> [PathPoint] {
        let trim = max(1, path.count * 8 / 100)
        guard path.count > trim * 2 + 4 else { return path }
        return Array(path[trim..<(path.count - trim)])
    }

    // MARK: - 比对

    /// 在候选里挑最像的一条
    static func bestMatch(path: [PathPoint],
                          candidates: [(gesture: Gesture, path: [PathPoint])])
    -> (gesture: Gesture, score: Double)? {
        var best: (Gesture, Double)?
        for candidate in candidates {
            let value = score(path, candidate.path)
            if best == nil || value > best!.1 {
                best = (candidate.gesture, value)
            }
        }
        guard let best, best.1 >= matchThreshold else { return nil }
        return (best.0, best.1)
    }

    // MARK: - 展示用

    /// 把轨迹压成 8 方位名字串，表格里用来一眼看出「这手势长什么样」。
    /// 例：先上后右 → "UR"
    static func directionString(_ path: [PathPoint]) -> String {
        guard path.count > 2 else { return "" }
        var labels: [Character] = []
        let step = max(1, path.count / 8)
        var index = step
        while index < path.count {
            let dx = path[index].x - path[index - step].x
            let dy = path[index].y - path[index - step].y
            let magnitude = hypot(dx, dy)
            if magnitude > 0.15 {
                let character = directionChar(dx: dx, dy: dy)
                if labels.last != character { labels.append(character) }
            }
            index += step
        }
        return String(labels)
    }

    private static func directionChar(dx: Double, dy: Double) -> Character {
        // 注意：模板坐标 y 轴向下（跟屏幕一致），所以 dy < 0 是"向上"
        let angle = atan2(dy, dx) * 180 / .pi   // -180…180
        switch angle {
        case -22.5..<22.5:      return "→"
        case 22.5..<67.5:       return "↘"
        case 67.5..<112.5:      return "↓"
        case 112.5..<157.5:     return "↙"
        case -67.5..<(-22.5):   return "↗"
        case -112.5..<(-67.5):  return "↑"
        case -157.5..<(-112.5): return "↖"
        default:                return "←"
        }
    }
}
