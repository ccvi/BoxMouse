import Foundation
import Darwin

// ============================================================
// 静默内存自回收
//
// 目的：把手势结束后积在 malloc 里的**空闲页**还给内核。
// 不刷数字、不碰系统缓存（那需要 root，且会让整机变慢）。
//
// 两条触发路径：
//   1. 静置 30 秒 —— 每轮手势结束后重新计时，期间又画了手势就重排
//   2. 超过阈值立刻归还 —— footprint 已经明显胖了，不等静置
//
// 为什么是事件驱动而不是定时轮询：
// 1 秒钟一次的采样就是 86400 次唤醒/天，而空闲时恰恰没什么可回收的。
// 手势结束是个天然的"该看一眼了"的时机，其余时间这个类完全在睡觉。
// ============================================================

final class MemoryReclaimer {

    static let shared = MemoryReclaimer()

    // MARK: - 可调参数

    /// 超过这个 footprint 就值得立刻归还。
    ///
    /// 实测：常态 75MB，打开主窗口时峰值 165MB。取 96MB——常态之上留 20MB 余量，
    /// 免得正常使用中也动不动来一次（虽然只要零点几毫秒，但没必要）。
    var thresholdBytes: UInt64 = 96 * 1024 * 1024

    /// 静置多久才动手
    var idleDelay: TimeInterval = 30

    /// 阈值触发的冷却时间。
    ///
    /// footprint 涨上去之后不会自己掉回来（SwiftUI 会把视图缓存留住），
    /// 没有冷却的话用户每画一笔就归还一次。60 秒一次够了。
    var immediateCooldown: TimeInterval = 60

    // MARK: - 内部状态

    private let queue = DispatchQueue(label: "com.pcxx.boxmousemac.memory", qos: .utility)
    private let lock = NSLock()

    private var pending: DispatchWorkItem?
    /// 每次重排 +1：靠它判断"回调回来时我还是不是最新的那一次"
    private var generation: UInt64 = 0
    private var lastImmediate: Date?

    /// 自检用的计数器
    private(set) var idleSweeps = 0
    private(set) var immediateSweeps = 0
    private(set) var lastReclaimedBytes = 0

    // MARK: - 对外入口

    /// 一轮手势结束（命中 / 未命中 / 执行失败都算）。
    ///
    /// 主线程调用；这里只做一次 footprint 读取（几十微秒）和一次任务重排，
    /// 真正的归还在后台队列上做，不占主线程。
    func gestureDidFinish() {
        // 先看要不要立刻还：读一次 footprint 比排定时器还便宜
        let footprint = MemoryReclaimer.footprintBytes()
        if footprint >= thresholdBytes, shouldRelieveImmediately() {
            queue.async { [weak self] in
                self?.relieveCountingImmediate()
            }
        }
        scheduleIdleSweep()
    }

    /// 立刻归还一次（诊断探针用，正常流程不会直接调）
    @discardableResult
    func relieveNow() -> (before: UInt64, reclaimed: Int, after: UInt64) {
        let before = MemoryReclaimer.footprintBytes()
        let reclaimed = MemoryReclaimer.relieve()
        let after = MemoryReclaimer.footprintBytes()
        lock.lock()
        lastReclaimedBytes = reclaimed
        lock.unlock()
        return (before, reclaimed, after)
    }

    // MARK: - 静置计时

    private func scheduleIdleSweep() {
        lock.lock()
        generation &+= 1
        let token = generation
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.idleSweepFired(token: token)
        }
        pending = work
        lock.unlock()
        // asyncAfter 的 work item 被 cancel 之后不一定不执行，所以回调里还要验 token
        queue.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    private func idleSweepFired(token: UInt64) {
        lock.lock()
        let isCurrent = (token == generation)
        pending = nil
        lock.unlock()
        guard isCurrent else { return }

        // 静置到了就还一次：
        // 此刻没人在画手势，归还哪怕只有几 MB 也没有任何代价。
        // 这里不看阈值——阈值是给"立刻还"那条路用的。
        _ = relieveNow()
        lock.lock()
        idleSweeps += 1
        lock.unlock()
    }

    private func shouldRelieveImmediately() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastImmediate, Date().timeIntervalSince(last) < immediateCooldown {
            return false
        }
        lastImmediate = Date()
        return true
    }

    private func relieveCountingImmediate() {
        _ = relieveNow()
        lock.lock()
        immediateSweeps += 1
        lock.unlock()
    }

    // MARK: - 底层

    /// 当前进程的 phys_footprint（和 `footprint` 命令报的是同一个数）
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size
            / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// 让 malloc 把空闲页 madvise 回内核，返回归还的字节数。
    ///
    /// `nil` = 所有 zone；goal 传 0 = 能还多少还多少（与 malloc.h 的说明一致）。
    ///
    /// ⚠️ **在本机（macOS 26 / arm64）实测返回 0，不是调用错了。**
    /// 实测数据（`--memrelief 200`）：4KB 小块占 200MB → footprint 203MB，
    /// free 之后立刻掉到 91.6MB——分配器自己就把 111MB 还给内核了；
    /// 此刻再调 pressure_relief，它手里已经没有空闲页可还。
    /// `malloc_get_all_zones` 也只返回 1 个 DefaultMallocZone。
    /// 也就是说：这个调用在当前系统上是个**安全但通常无事可做**的兜底，
    /// 留着是因为别的系统版本/碎片化场景下它仍有意义，成本又只有零点几毫秒。
    /// 想验证就自己跑 `BoxMouse --memrelief`，别靠猜。
    @discardableResult
    static func relieve() -> Int {
        malloc_zone_pressure_relief(nil, 0)
    }
}
