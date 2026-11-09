import CoreMedia
import CoreVideo
import Foundation
import ReplayKit
import os

/// T03 の仮実装: 受け取ったフレームの統計（設計書13章の1・2・8）。T05 で作り直す。
struct FrameStats {
    private(set) var frames = 0
    private(set) var framesWithoutImage = 0
    private(set) var pixelFormat = "-"
    private(set) var width = 0
    private(set) var height = 0
    private(set) var orientation: Int?
    private(set) var lastGap: Double = 0
    private(set) var maxGap: Double = 0
    private(set) var gapsOver1s = 0
    private var lastArrival: Double?
    private var recentArrivals: [Double] = []

    /// `now` はフレームが届いた時刻（`ProcessInfo.processInfo.systemUptime`）。
    mutating func add(_ sampleBuffer: CMSampleBuffer, now: Double) {
        frames += 1
        if let last = lastArrival {
            let gap = now - last
            lastGap = gap
            maxGap = max(maxGap, gap)
            if gap > 1.0 { gapsOver1s += 1 }
        }
        lastArrival = now
        recentArrivals.append(now)
        recentArrivals.removeAll { now - $0 > 1.0 }

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            pixelFormat = Self.fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
        } else {
            framesWithoutImage += 1
        }
        if let value = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber {
            orientation = value.intValue
        }
    }

    /// 直近1秒に届いたフレームの数。
    func fps(now: Double) -> Int {
        recentArrivals.filter { now - $0 <= 1.0 }.count
    }

    /// `broadcast.debug.summary` に入れる1行。
    func summary(now: Double) -> String {
        var parts = [
            "frames=\(frames)",
            "fmt=\(pixelFormat)",
            "size=\(width)x\(height)",
            "fps=\(fps(now: now))",
            String(format: "gap=%.3f", lastGap),
            String(format: "maxGap=%.2f", maxGap),
            "gaps>1s=\(gapsOver1s)",
            "orient=\(orientation.map(String.init) ?? "-")",
        ]
        if framesWithoutImage > 0 { parts.append("noImage=\(framesWithoutImage)") }
        if let used = MemoryInfo.footprintMB() { parts.append(String(format: "mem=%.1fMB", used)) }
        parts.append(String(format: "free=%.1fMB", MemoryInfo.availableMB()))
        return parts.joined(separator: " ")
    }

    /// ピクセル形式の FourCC。`420f`（フルレンジ）か `420v`（ビデオレンジ）のはず。
    static func fourCC(_ type: OSType) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((type >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08x", type)
    }
}

/// 録画拡張のメモリ。上限は 50MB（設計書7章）。
enum MemoryInfo {
    /// 使っているメモリ（phys_footprint）。Xcode の Debug Navigator の値に近い。
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// あとどれだけ使えるか。
    static func availableMB() -> Double {
        Double(os_proc_available_memory()) / 1_048_576
    }
}
