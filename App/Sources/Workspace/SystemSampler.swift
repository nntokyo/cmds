import Darwin
import Foundation
import CmdsCore

/// Machine-wide usage: what goes on the wire (`stats`) plus the breakdown shown in the sidebar tooltip.
struct SystemSample: Sendable {
    var stats: SystemStats
    var appMemoryBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var swapUsedBytes: UInt64?
    var swapTotalBytes: UInt64?
    var cpuCount: Int
}

/// Reads total CPU load (`host_statistics` tick deltas), memory used (`host_statistics64` page counts, as
/// Activity Monitor's "Memory Used"), memory pressure and swap. A few syscalls, no processes spawned.
/// Not thread-safe: use from one queue.
final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        if host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 { return UInt64(size) }
        return UInt64(getpagesize())
    }()
    private var previousTicks: CPULoadTicks?

    /// nil on the first call (CPU load needs two readings) or if the kernel calls fail.
    func sample() -> SystemSample? {
        guard let ticks = cpuTicks() else { return nil }
        defer { previousTicks = ticks }
        guard let previous = previousTicks, let cpu = ticks.busyPercent(since: previous),
              let vm = vmStatistics() else { return nil }
        let used = MemoryAccounting.usedBytes(internalPages: UInt64(vm.internal_page_count),
                                              purgeablePages: UInt64(vm.purgeable_count),
                                              wiredPages: UInt64(vm.wire_count),
                                              compressorPages: UInt64(vm.compressor_page_count),
                                              pageSize: pageSize)
        let app = UInt64(vm.internal_page_count) > UInt64(vm.purgeable_count)
            ? (UInt64(vm.internal_page_count) - UInt64(vm.purgeable_count)) * pageSize : 0
        let swap = swapUsage()
        let stats = SystemStats(cpuPercent: (cpu * 10).rounded() / 10, memoryUsedBytes: used,
                                memoryTotalBytes: ProcessInfo.processInfo.physicalMemory,
                                memoryPressure: memoryPressureLevel())
        return SystemSample(stats: stats, appMemoryBytes: app, wiredBytes: UInt64(vm.wire_count) * pageSize,
                            compressedBytes: UInt64(vm.compressor_page_count) * pageSize,
                            swapUsedBytes: swap?.used, swapTotalBytes: swap?.total,
                            cpuCount: ProcessInfo.processInfo.activeProcessorCount)
    }

    private func cpuTicks() -> CPULoadTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // cpu_ticks is indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        return CPULoadTicks(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func vmStatistics() -> vm_statistics64? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    private func memoryPressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    private func swapUsage() -> (used: UInt64, total: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (usage.xsu_used, usage.xsu_total)
    }
}
