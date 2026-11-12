import Foundation
import CoreGraphics

// ============================================================
// 平滑滚轮
//
// 鼠标滚轮是「档」的：一格 = 系统约 3 行，页面一次跳一段。触控板则是像素级
// 连续滚动、还带系统自己的惯性。这个类只负责前者——把离散的行滚动摊成
// 逐帧的像素滚动，做出缓动收尾的手感。
//
// 三条实现约束：
//
// ① **只处理离散滚轮**。触控板 / 妙控鼠标的事件带 `IsContinuous = 1`，系统
//    已经平滑过了，再平滑一次会变成"双重惯性"，手感发飘。调用方负责分流。
//
// ② **派发的事件必须打 replayMark**。事件 tap 挂在 `.cgSessionEventTap` 最上游，
//    我们自己 post 出去的事件会再次流经自己的回调——不打标记就是
//    吞 → 派发 → 再吞 → 再派发，滚轮卡死。标记值和手势重放共用。
//
// ③ **总量守恒，不过冲**。用「目标位移 + 每帧取一部分」而不是「速度 + 衰减」：
//    速度模型在收尾时会冲过目标，用户感觉"多滚了一截"；目标模型无论怎么缓，
//    消耗的总和恒等于输入量，滚多少就是多少。
//
// 滚多少：一档（lineDelta = 1）按 `baseLineHeight × strength` 像素算。
// 40 接近 macOS 上 Safari / 预览一档的观感，强度倍率再乘上去。
// ============================================================

final class SmoothScroller {

    /// 一档滚轮折算的基准像素高度
    static let baseLineHeight: Double = 40
    /// 每帧吃掉待滚位移的比例。0.30 ≈ 60Hz 下 8 帧收敛，收尾有肉感但不会拖泥带水
    private let catchUp: Double = 0.30
    /// 帧间隔：120Hz。比 60Hz 更跟手，代价是滚动期间每秒多派发 60 次事件
    private let frameInterval: TimeInterval = 1.0 / 120
    /// 待滚位移小于这个值就直接收尾，避免无限逼近产生一串 0 像素事件
    private let stopThreshold: Double = 0.8

    private var pendingX: Double = 0
    private var pendingY: Double = 0
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    /// 记最近一次派发的事件时间，供自检/诊断看"到底有没有动"
    private(set) var dispatchedEvents = 0

    /// 喂一次滚轮输入（单位：像素，符号与 CGEvent 的 pointDelta 一致）
    func feed(pixelsX: Double, pixelsY: Double) {
        guard pixelsX != 0 || pixelsY != 0 else { return }
        lock.lock()
        pendingX += pixelsX
        pendingY += pixelsY
        let shouldStart = timer == nil
        lock.unlock()
        if shouldStart { startTimer() }
    }

    /// 把待滚位移全部清掉（关掉开关、或者要立刻停住时用）
    func reset() {
        lock.lock()
        pendingX = 0
        pendingY = 0
        lock.unlock()
        stopTimer()
    }

    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timer == nil && pendingX == 0 && pendingY == 0
    }

    // MARK: - 逐帧派发

    private func startTimer() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        source.schedule(deadline: .now(), repeating: frameInterval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        lock.unlock()
        source.resume()
    }

    private func stopTimer() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
    }

    private func tick() {
        lock.lock()
        let remainingX = pendingX
        let remainingY = pendingY

        var stepX = remainingX * catchUp
        var stepY = remainingY * catchUp
        let doneX = abs(remainingX) <= stopThreshold
        let doneY = abs(remainingY) <= stopThreshold
        if doneX { stepX = remainingX }
        if doneY { stepY = remainingY }

        pendingX = doneX ? 0 : remainingX - stepX
        pendingY = doneY ? 0 : remainingY - stepY
        let finished = pendingX == 0 && pendingY == 0
        lock.unlock()

        // 🔴 按**取整后**的值判断要不要发。余量小于 1px 时 step 取整是 0，
        // 这时候发出去的就是一条「0 像素」的滚轮事件：应用白跑一趟，
        // 尾巴上还会连着几条，实测一档滚轮能多发两三条空事件。
        let eventX = Int32(stepX.rounded())
        let eventY = Int32(stepY.rounded())
        if eventX != 0 || eventY != 0 {
            post(pixelsX: eventX, pixelsY: eventY)
        }
        if finished { stopTimer() }
    }

    /// 派发一帧滚动。`units: .pixel` + `IsContinuous = 1`：前者告诉应用这是
    /// 像素级滚动，后者让它按"连续设备"处理（浏览器据此走像素滚动而不是按行跳），
    /// 缺了任何一个都会退回一格一格跳。
    private func post(pixelsX: Int32, pixelsY: Int32) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: pixelsY,
                                  wheel2: pixelsX,
                                  wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // 🔴 不打这个标记，事件会再次进我们自己的 tap → 死循环
        event.setIntegerValueField(.eventSourceUserData, value: GestureEngine.replayMark)
        event.post(tap: .cgSessionEventTap)
        dispatchedEvents += 1
    }
}
