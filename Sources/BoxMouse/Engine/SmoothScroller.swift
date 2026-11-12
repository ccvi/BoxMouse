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
    /// 收尾阈值：剩余距离和本帧速度都低于它才算走完（MMF 的 stopTolerance）
    private let stopTolerance: Double = 0.5
    /// display link 起不来时的兜底节拍
    private let fallbackInterval: TimeInterval = 1.0 / 120

    // MARK: - 状态（锁保护：feed 在主线程，逐帧回调在显示链接线程）

    /// 目标位移（像素，符号与 CGEvent 的 pointDelta 一致）
    private(set) var buffer = (x: 0.0, y: 0.0)
    /// 已画出去的位移
    private(set) var current = (x: 0.0, y: 0.0)
    /// 上一笔输入的方向，用来判"同向累加 / 反向重来"
    private var lastInput = (x: 0.0, y: 0.0)
    /// 攒着的不足一帧的位移
    private var carry = (x: 0.0, y: 0.0)

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

    // MARK: - 输入

    /// 喂一次滚轮输入（单位：像素，符号与 CGEvent 的 pointDelta 一致）
    ///
    /// - Parameters:
    ///   - duration: 缓动总时长（秒），内部换算成时间常数 τ = duration/3
    ///   - gain: 连续滚动时的速度增益，1.0 = 不加速
    func feed(pixelsX: Double, pixelsY: Double,
              duration: Double = SmoothScroller.defaultDuration,
              gain: Double = SmoothScroller.defaultGain) {
        guard pixelsX != 0 || pixelsY != 0 else { return }

        lock.lock()
        self.duration = min(0.6, max(0.06, duration))

        // 连续滚动才吃增益：上一次还没走完，说明用户在接着滚。
        // 单格滚轮不加速，否则"轻轻滚一格"也会冲出去，和预期不符。
        let busy = abs(buffer.x - current.x) > busyThreshold
            || abs(buffer.y - current.y) > busyThreshold
        let multiplier = busy ? min(4.0, max(1.0, gain)) : 1.0

        // 同向 → 累加到目标；反向 → 目标换成新值，已画出的量归零
        if pixelsY * lastInput.y > 0 {
            buffer.y += pixelsY * multiplier
        } else {
            buffer.y = pixelsY * multiplier
            current.y = 0
            carry.y = 0
        }
        if pixelsX * lastInput.x > 0 {
            buffer.x += pixelsX * multiplier
        } else {
            buffer.x = pixelsX * multiplier
            current.x = 0
            carry.x = 0
        }
        lastInput = (x: pixelsX, y: pixelsY)
        lastFrameTime = 0

        let needStart = !driverRunning
        lock.unlock()

        if needStart { startDriver() }
    }

    /// 把待滚位移全部扔掉（关开关、停引擎、切应用时用）
    func reset() {
        lock.lock()
        buffer = (0, 0)
        current = (0, 0)
        carry = (0, 0)
        lastInput = (0, 0)
        lastFrameTime = 0
        lock.unlock()
        stopDriver()
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return abs(buffer.x - current.x) < deadZone
            && abs(buffer.y - current.y) < deadZone
            && carry.x == 0 && carry.y == 0
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
        stepX = min(maxFramePixels, max(-maxFramePixels, stepX))
        stepY = min(maxFramePixels, max(-maxFramePixels, stepY))

        current.x += stepX
        current.y += stepY

        let restX = buffer.x - current.x
        let restY = buffer.y - current.y
        // 收尾：剩下的距离和这一帧的速度都小到看不见（MMF 的 stopTolerance）
        let settled = abs(restX) < stopTolerance && abs(restY) < stopTolerance
            && abs(stepX) < stopTolerance && abs(stepY) < stopTolerance
        if settled {
            // 收尾帧：残余一起补上，保证总位移与输入严格相等
            stepX += restX
            stepY += restY
            current = buffer
        }

        // 整数部分给 pointDelta，余下的零头攒到下一帧——
        // 🔴 pointDelta 只能存整数，小数部分不自己攒就会一帧一帧地漏掉
        // （实测一档滚轮能漏掉 1/4 的位移）。小数本身走 FixedPt 不丢。
        let wholeX = Int32((stepX + carry.x).rounded(.towardZero))
        let wholeY = Int32((stepY + carry.y).rounded(.towardZero))
        carry.x = stepX + carry.x - Double(wholeX)
        carry.y = stepY + carry.y - Double(wholeY)

        framesTicked += 1
        if settled {
            buffer = (0, 0)
            current = (0, 0)
            lastInput = (0, 0)
            lastFrameTime = 0
            carry = (0, 0)
        }
        lock.unlock()

        // 每拍都发：攒着不发会让帧间隔变成 2、3 个刷新周期，看着就是顿
        if runsDriver, stepX != 0 || stepY != 0 {
            post(wholeX: wholeX, wholeY: wholeY, dx: stepX, dy: stepY)
        }
        if settled {
            stopDriver()
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
    private func post(wholeX: Int32, wholeY: Int32, dx: Double, dy: Double) {
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
        // 🔴 不打这个标记，事件会再次进我们自己的 tap → 死循环
        event.setIntegerValueField(.eventSourceUserData, value: GestureEngine.replayMark)
        event.post(tap: .cgSessionEventTap)
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
