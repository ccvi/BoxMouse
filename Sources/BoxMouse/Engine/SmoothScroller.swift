import Foundation
import CoreGraphics
import CoreVideo
import QuartzCore

// ============================================================
// 平滑滚轮
//
// 鼠标滚轮是「档」的：一格 = 系统约 3 行，页面一次跳一段。这个类把离散的
// 档位摊成逐帧的亚像素滚动，做出带缓动收尾的手感。
//
// 参照了两个成熟实现，各取所长：
//
// **Mos（Caldis/Mos, ScrollPoster）** —— 取它的运动模型：
//   两个位置变量 + 逐帧逼近。`buffer` 是目标位移（同向累加），`current` 是已经
//   画出去的量；每帧 `step = (buffer - current) × factor`，`current += step`。
//   同向连续输入是**累加**进 buffer 的，所以"越滚越快"是自然结果，不用额外写
//   加速逻辑；反向输入直接把 buffer 换成新值、current 归零——否则手指已经反过
//   来了，屏幕还在往原方向飘一截。它还带一个「速度增益」，只在连续滚动时乘到
//   输入上（我们照做）。
//
// **Mac Mouse Fix（noah-nuebling/mac-mouse-fix, Scroll / DynamicSystemAnimator）** ——
//   取它两件事：
//   ① 🔴 **亚像素**。`PointDelta` 按 double 写（`setDoubleValueField`）。整像素
//      Round 掉以后，一档滚轮只能发出 12、8、6、4、3、2、1 这种台阶，再好的
//      曲线也是"一下一下跳"。MMF 专门写了 VectorSubPixelator 就是为这个。
//      Mos 的快照里同样是 `setDoubleValueField(.scrollWheelEventPointDeltaAxis1)`。
//   ② **收尾按"距离 + 速度都足够小"判定**（它的 epsilon/stopTolerance），
//      而不是只看剩余距离——只看距离会在尾巴上一直发亚像素事件。
//
// ③ 驱动用 **CVDisplayLink**，不是定时器。定时器相位和屏幕刷新对不齐，120Hz 下
//    会规律性地"这一帧走两步、下一帧原地不动"，看着就是微抖。两家都是显示链接
//    （MMF 还额外做了相位对齐）。链接建不起来时退回 120Hz 定时器。
//
// 没抄的部分：MMF 的 HybridCurve（先匀速再切拖拽曲线）是为了"触控板式惯性"，
// 我们的输入是离散档位、没有 momentum 阶段，用不上；它的 DynamicSystemAnimator
// 是弹簧模型，那是给 UI 动画用的（源码注释里自己说了滚动这条线还在用曲线）。
//
// 滚多少：一档（lineDelta = 1）按 `baseLineHeight × 倍率` 像素算，40 接近
// Safari / 预览一档的观感。
// ============================================================

final class SmoothScroller {

    /// 一档滚轮折算的基准像素高度（Mos 的「最短步长」默认 48）
    static let baseLineHeight: Double = 40
    /// 默认缓动时长（秒）：一格滚轮从开始到走到位的总时间
    static let defaultDuration: Double = 0.22
    /// 默认速度增益：1.0 = 不加速
    static let defaultGain: Double = 1.0

    /// 单帧最多发多少像素：防异常输入（或长时间卡顿后）一次性灌爆
    private let maxFramePixels: Double = 240
    /// 空闲判定阈值：剩余位移和攒着的零头都小于它就算走完了
    private let deadZone: Double = 0.35
    /// 判定"上一次还没走完"的余量（像素）
    private let busyThreshold: Double = 1.0
    /// 收尾阈值：剩余距离和本帧速度都低于它就算走完（MMF 的 stopTolerance）
    ///
    /// 🔴 取 1px 而不是更小，**而且收尾之前一帧都不能丢**：
    ///   ① 丢帧（"不足 1px 就不发"）看着像省事，实测会把尾巴变成
    ///      34 / 33 / 50 / 68ms 的空档——滚动管线以为手势断了，比发 0 像素更难 看；
    ///   ② 不提前收又会一直爬 0.2px 爬两百毫秒。
    /// 所以：节拍保持满帧，剩 1px 时一刀切。Mos 实测也是这样（28 帧全程 16.7ms）。
    static let stopTolerance: Double = 1.0
    /// display link 起不来时的兜底节拍
    private let fallbackInterval: TimeInterval = 1.0 / 120

    /// 起步斜坡：从静止起手时，前几帧只走这个比例（Mos 的曲线峰值滤波器
    /// 0.23 / 0.5 / 0.77）。
    ///
    /// 没有它的话第一帧就窜出 15% 的总位移（180px 的一格 = 27px / 16.7ms，
    /// 瞬时速度 1600px/s），观感是"先顿一下再滑"；有了它起步是软的。
    /// 🔴 缩放的是**这一帧的步长**，不是目标位移，所以总距离一分不少——
    /// 差额留在 buffer 里，指数逼近自然会补回来。
    static let rampWeights: [Double] = [0.23, 0.5, 0.77]

    // MARK: - 状态（锁保护：feed 在主线程，逐帧回调在显示链接线程）

    /// 目标位移（像素，符号与 CGEvent 的 pointDelta 一致）
    private(set) var buffer = (x: 0.0, y: 0.0)
    /// 已画出去的位移
    private(set) var current = (x: 0.0, y: 0.0)
    /// 上一笔输入的方向，用来判"同向累加 / 反向重来"
    private var lastInput = (x: 0.0, y: 0.0)
    /// 已经真正发出去的位移（`current` 是"应该画到哪"，它是"画到了哪"）
    ///
    /// 🔴 这两个必须分开记：小于 1px 的帧被丢掉时 `current` 照样前进，但那部分
    /// 位移还没发出去，要攒到下一帧一起补。早先用 `carry` 记零头、又把它同时算进
    /// 本帧的位移，结果一档滚轮多滚了 5.8px（实测）。
    private var delivered = (x: 0.0, y: 0.0)
    /// 起步斜坡还剩几帧
    private(set) var rampFramesLeft = 0

    /// 这一轮滚动的目标进程（`CGEventPostToPid` 直投用）。
    ///
    /// 🔴 直投是为了绕开"回发到会话层再让窗口服务器重新命中测试"这一跳。
    /// 代价是系统不再帮我们判断"现在光标在谁身上"，所以**目标一变就得把残量扔掉**，
    /// 否则滚动动画会把剩下的几十像素打到用户新切过去的窗口上。
    private(set) var targetPid: pid_t = 0

    private var duration: Double = SmoothScroller.defaultDuration
    private var gain: Double = SmoothScroller.defaultGain
    private var lastFrameTime: CFTimeInterval = 0
    /// 一帧的真实长度：第一拍没有上一拍可比，用它当 dt。
    /// 写死 1/120 的话，60Hz 屏上第一帧只走一半、第二帧补回来，
    /// 观感是"先轻轻一动、再猛地一窜"。
    private var nominalInterval: TimeInterval = 1.0 / 60.0

    private let lock = NSLock()
    private var link: CVDisplayLink?
    private var timer: DispatchSourceTimer?
    private var driverRunning = false

    /// 自检用：置 false 时只算状态、不真派发事件（否则跑自检会把当前应用滚一下）
    var runsDriver = true

    /// 派发过多少条事件（诊断/自检看"到底有没有动"）
    private(set) var dispatchedEvents = 0
    /// 跑过多少帧（诊断用：和事件数一起看，能区分"没帧"和"有帧但没位移"）
    private(set) var framesTicked = 0
    /// 这一轮开始时两个计数器的读数，收尾时相减得到"这一轮发了多少"
    private var burstFrameBase = 0
    private var burstPostBase = 0

    // MARK: - 输入

    /// 喂一次滚轮输入（单位：像素，符号与 CGEvent 的 pointDelta 一致）
    ///
    /// - Parameters:
    ///   - duration: 缓动总时长（秒），内部换算成时间常数 τ = duration/3
    ///   - gain: 连续滚动时的速度增益，1.0 = 不加速
    ///   - targetPid: 这条输入要投给哪个进程（原事件的 `eventTargetUnixProcessID`）。
    ///     给 0 就退回"回发到会话层"的老路径。
    func feed(pixelsX: Double, pixelsY: Double,
              duration: Double = SmoothScroller.defaultDuration,
              gain: Double = SmoothScroller.defaultGain,
              targetPid: pid_t = 0) {
        guard pixelsX != 0 || pixelsY != 0 else { return }

        lock.lock()
        self.duration = min(0.6, max(0.06, duration))

        // 目标换了：先把残量扔掉再接受新输入（否则残帧会打到新窗口）
        if targetPid != 0, self.targetPid != 0, targetPid != self.targetPid {
            buffer = (0, 0)
            current = (0, 0)
            delivered = (0, 0)
            lastInput = (0, 0)
            rampFramesLeft = 0
        }
        if targetPid != 0 { self.targetPid = targetPid }

        // 连续滚动才吃增益：上一次还没走完，说明用户在接着滚。
        // 单格滚轮不加速，否则"轻轻滚一格"也会冲出去，和预期不符。
        let busy = abs(buffer.x - current.x) > busyThreshold
            || abs(buffer.y - current.y) > busyThreshold
        let multiplier = busy ? min(4.0, max(1.0, gain)) : 1.0

        // 从静止起手才做起步斜坡。连续滚动中途不做——否则每加一格都重新软一下，
        // 快滚的时候会一顿一顿的。
        if !busy { rampFramesLeft = Self.rampWeights.count }

        // 同向 → 累加到目标；反向 → 目标换成新值，已画出的量归零
        if pixelsY * lastInput.y > 0 {
            buffer.y += pixelsY * multiplier
        } else {
            buffer.y = pixelsY * multiplier
            current.y = 0
            delivered.y = 0
        }
        if pixelsX * lastInput.x > 0 {
            buffer.x += pixelsX * multiplier
        } else {
            buffer.x = pixelsX * multiplier
            current.x = 0
            delivered.x = 0
        }
        lastInput = (x: pixelsX, y: pixelsY)
        lastFrameTime = 0

        let needStart = !driverRunning
        let logPid = targetPid
        lock.unlock()

        // 一轮开头写一行诊断：滚了多少、投给谁。用户报"滚轮没反应"时，
        // 看这行就知道是没进引擎、还是进了但投错了目标。
        TrackpadEngine.trace(String(format: "滚轮 输入 %.1f/%.1f px → 目标 pid %d%@",
                                    pixelsX, pixelsY, logPid,
                                    needStart ? "（起步）" : "（续滚）"))

        if needStart {
            burstFrameBase = framesTicked
            burstPostBase = dispatchedEvents
            startDriver()
        }
    }

    /// 把待滚位移全部扔掉（关开关、停引擎、切应用时用）
    func reset() {
        lock.lock()
        buffer = (0, 0)
        current = (0, 0)
        delivered = (0, 0)
        lastInput = (0, 0)
        lastFrameTime = 0
        rampFramesLeft = 0
        targetPid = 0
        lock.unlock()
        stopDriver()
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abs(buffer.x - current.x) < deadZone
            && abs(buffer.y - current.y) < deadZone
            && delivered.x == current.x && delivered.y == current.y
    }

    // MARK: - 逐帧逼近

    /// 每帧吃掉多少比例：按**实测 dt** 算，帧率无关。
    ///
    /// 这一点比 Mos 更进一步：它把 `duration` 当成"每帧的固定插值系数"直接传给
    /// lerp，60Hz 上调好的手感搬到 120Hz 的 ProMotion 屏上就快一倍（同样的
    /// 系数、两倍的帧数）。我们换算成时间常数 τ = duration/3（3τ ≈ 95%），
    /// 再用 dt 反推系数，换屏幕不会变调。
    static func frameFactor(dt: TimeInterval, duration: Double) -> Double {
        let tau = max(0.02, duration / 3)
        return 1 - exp(-max(0, dt) / tau)
    }

    /// 显示链接 / 定时器每拍走这里
    fileprivate func tick(now: CFTimeInterval) {
        lock.lock()
        let dt = lastFrameTime == 0 ? nominalInterval : min(0.05, now - lastFrameTime)
        lastFrameTime = now

        let factor = Self.frameFactor(dt: dt, duration: duration)
        var stepX = (buffer.x - current.x) * factor
        var stepY = (buffer.y - current.y) * factor

        // 起步斜坡：头几帧只走其中一部分，差额留在 buffer 里由指数逼近补回来，
        // 所以总位移不变，只是前 3 帧（约 50ms）速度爬坡。
        if rampFramesLeft > 0 {
            let index = Self.rampWeights.count - rampFramesLeft
            let weight = Self.rampWeights[min(index, Self.rampWeights.count - 1)]
            stepX *= weight
            stepY *= weight
            rampFramesLeft -= 1
        }

        stepX = min(maxFramePixels, max(-maxFramePixels, stepX))
        stepY = min(maxFramePixels, max(-maxFramePixels, stepY))

        current.x += stepX
        current.y += stepY

        let restX = buffer.x - current.x
        let restY = buffer.y - current.y
        // 收尾：剩下的距离和这一帧的速度都小到看不见（MMF 的 stopTolerance）
        let settled = abs(restX) < Self.stopTolerance && abs(restY) < Self.stopTolerance
            && abs(stepX) < Self.stopTolerance && abs(stepY) < Self.stopTolerance
        if settled {
            // 收尾帧：残余一起补上，保证总位移与输入严格相等
            stepX += restX
            stepY += restY
            current = buffer
        }

        // 这一帧该补出去的位移 = 应该画到的 − 已经发出去的。
        // 🔴 pointDelta 只存整数（实测写 3.4 读回 3.0、写 0.4 变 0），所以整数部分
        // 给它、完整的量给 FixedPt；被丢掉的那些帧不推进 `delivered`，零头自动
        // 攒到下一帧，一档滚轮一分都不会漏。
        let exactX = current.x - delivered.x
        let exactY = current.y - delivered.y
        let wholeX = Int32(exactX.rounded(.towardZero))
        let wholeY = Int32(exactY.rounded(.towardZero))

        let pid = targetPid
        framesTicked += 1
        if settled {
            buffer = (0, 0)
            current = (0, 0)
            lastInput = (0, 0)
            lastFrameTime = 0
            delivered = (0, 0)
            rampFramesLeft = 0
            targetPid = 0
        }
        lock.unlock()

        // 🔴 每一拍都发，哪怕这一帧的整数位移是 0：
        // 发 0 像素看着浪费，但发不发决定了连贯性——应用靠"有没有事件"判断手势还在不在，
        // 断拍会被当成滚动结束。Mos 的实测帧流里同样有 0 像素帧，而它的节拍是满的。
        if runsDriver {
            post(wholeX: wholeX, wholeY: wholeY, dx: exactX, dy: exactY, pid: pid)
            lock.lock()
            delivered.x = current.x
            delivered.y = current.y
            lock.unlock()
        }
        if settled {
            stopDriver()
            TrackpadEngine.trace("滚轮 收尾：\(framesTicked - burstFrameBase) 帧 / 派出 \(dispatchedEvents - burstPostBase) 条")
        }
    }


    // MARK: - 派发

    /// 一帧滚轮事件。
    ///
    /// 🔴 两套字段都要写，各管一半应用：
    /// - `PointDelta`（整数像素）：绝大多数应用读这个。实测它**存不了小数**
    ///   （写 3.4 读回来是 3.0，写 0.4 直接变 0），所以小数部分由调用方攒进
    ///   下一帧，否则一档滚轮会漏掉四分之一。
    /// - `FixedPtDelta`（16.16 定点）：NSEvent 的 `scrollingDeltaY` 走这条，
    ///   能吃到亚像素，尾部那种 0.6px 的小步才不会变成"一秒一下"。
    ///
    /// 🔴 投递走 `CGEventPostToPid`，不回发到会话层（Mos 的做法，见它 PR #523）：
    /// 会话层回发要重新过一遍窗口服务器的命中测试和 tap 链，每帧多一跳延迟，还会
    /// 被别的同类工具（比如同时开着的 Mos）再处理一次。直投就是"这条事件只给这个
    /// 进程"，剩下的判断交回给应用自己。
    private func post(wholeX: Int32, wholeY: Int32, dx: Double, dy: Double, pid: pid_t) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: wholeY,
                                  wheel2: wholeX,
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1,
                                   value: Int64((dy * 65536).rounded()))
        event.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2,
                                   value: Int64((dx * 65536).rounded()))
        // 连续事件：浏览器据此走像素滚动，而不是"一格一格跳"
        event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1)
        // 🔴 不打这个标记，事件会再次进我们自己的 tap → 死循环（退回会话层时才会撞上）
        event.setIntegerValueField(.eventSourceUserData, value: GestureEngine.replayMark)
        if pid > 0 {
            event.postToPid(pid)
        } else {
            event.post(tap: .cgSessionEventTap)
        }
        dispatchedEvents += 1
    }

    // MARK: - 驱动

    private func startDriver() {
        guard runsDriver else { return }
        lock.lock()
        guard !driverRunning else { lock.unlock(); return }
        driverRunning = true
        lock.unlock()

        if link == nil {
            var created: CVDisplayLink?
            if CVDisplayLinkCreateWithActiveCGDisplays(&created) == kCVReturnSuccess,
               let created {
                CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
                    guard let context else { return kCVReturnSuccess }
                    Unmanaged<SmoothScroller>.fromOpaque(context)
                        .takeUnretainedValue()
                        .tick(now: CACurrentMediaTime())
                    return kCVReturnSuccess
                }, Unmanaged.passUnretained(self).toOpaque())
                // 取这个显示链接的真实帧长，做第一帧的 dt
                let period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(created)
                if period.timeValue > 0, period.timeScale > 0 {
                    let seconds = Double(period.timeValue) / Double(period.timeScale)
                    if seconds > 0.001, seconds < 0.1 { nominalInterval = seconds }
                }
                link = created
            }
        }

        if let link, CVDisplayLinkStart(link) == kCVReturnSuccess {
            return
        }
        // 显示链接起不来（虚拟机、无活动显示器…）：退回定时器，至少还能滚
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: fallbackInterval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            self?.tick(now: CACurrentMediaTime())
        }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    private func stopDriver() {
        lock.lock()
        let runningLink = link
        let runningTimer = timer
        timer = nil
        driverRunning = false
        lock.unlock()

        if let runningLink, CVDisplayLinkIsRunning(runningLink) {
            CVDisplayLinkStop(runningLink)
        }
        runningTimer?.cancel()
    }
}
