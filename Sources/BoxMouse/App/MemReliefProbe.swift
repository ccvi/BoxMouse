import Foundation
import Darwin

// ============================================================
// `--memrelief [MB]` 内存归还探针
//
// 两件事必须分清楚，混在一起测会得出错误结论：
//
//   小对象（4KB，落在 MALLOC_SMALL）—— 应用里内存的真实形态，
//     malloc_zone_pressure_relief 能 madvise 掉其中的空闲页
//   大对象（1MB，≥128KB 走 "large" 路径）—— free 之后往往直接 munmap
//     还给内核，压根不经过 zone，pressure relief 自然数不出东西
//
// 所以第一版只测 1MB 块，得到"归还 0 字节"，是**测法不对**而不是功能失效。
//
// 用法：
//   BoxMouse --memrelief         默认每档 200MB
//   BoxMouse --memrelief 512
// ============================================================

enum MemReliefProbe {

    static func run(megabytes: Int = 200) -> Int32 {
        print("内存归还探针（每档 \(megabytes) MB）")
        print("────────────────────────────────────────")

        let base = MemoryReclaimer.footprintBytes()
        print(String(format: "基线 footprint      %8.1f MB", toMB(base)))

        let small = round(label: "小对象 4KB × \(megabytes * 256)",
                          blockSize: 4096,
                          count: megabytes * 256)
        print("")

        let large = round(label: "大对象 1MB × \(megabytes)",
                          blockSize: 1 << 20,
                          count: megabytes)
        print("────────────────────────────────────────")

        switch (small, large) {
        case (true, true):
            print("✓ 两种形态都能归还")
            return 0
        case (true, false):
            print("✓ 小对象能归还（这才是应用里的常态）；大对象 free 时已直接还给内核")
            return 0
        case (false, true):
            print("⚠️ 只有大对象归还成功，小对象没量到——需要复查")
            return 2
        case (false, false):
            print("⚠️ 两档都归还 0 字节，需要复查（不是\"功能没坏\"的结论）")
            return 2
        }
    }

    /// 用指定大小的块占一片内存 → 全部 free → 归还，量出归还了多少
    private static func round(label: String, blockSize: Int, count: Int) -> Bool {
        let before = MemoryReclaimer.footprintBytes()

        var blocks: [UnsafeMutableRawPointer] = []
        blocks.reserveCapacity(count)
        for _ in 0..<count {
            guard let raw = malloc(blockSize) else { break }
            memset(raw, 0xA5, blockSize)   // 必须碰一下，否则内核不给物理页
            blocks.append(raw)
        }
        let held = MemoryReclaimer.footprintBytes()
        print(String(format: "%@", label))
        print(String(format: "  占用后 footprint  %8.1f MB（+%.1f）",
                     toMB(held), toMB(held) - toMB(before)))

        for raw in blocks { free(raw) }
        blocks.removeAll()

        let freed = MemoryReclaimer.footprintBytes()
        print(String(format: "  free 后           %8.1f MB（−%.1f，malloc 留着复用）",
                     toMB(freed), toMB(held) - toMB(freed)))

        let result = MemoryReclaimer.shared.relieveNow()
        print(String(format: "  relieve 归还      %8.1f MB", toMB(UInt64(max(0, result.reclaimed)))))
        print(String(format: "  归还后            %8.1f MB（相对 free 后再降 %.1f）",
                     toMB(result.after), toMB(freed) - toMB(result.after)))

        return result.reclaimed > 0
    }

    private static func toMB(_ bytes: UInt64) -> Double {
        Double(bytes) / 1024 / 1024
    }
}
