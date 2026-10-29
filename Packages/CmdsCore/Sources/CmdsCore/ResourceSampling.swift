import Foundation

// Platform-independent math behind the Mac app's CPU/memory sampling (the syscalls live in the app).

/// Mach absolute time conversion. On Apple Silicon one tick is 125/3 ns (`mach_timebase_info` 125/3);
/// `rusage_info` CPU times and `mach_absolute_time()` use these units.
public enum MachTime {
    public static func nanoseconds(_ ticks: UInt64, numer: UInt32, denom: UInt32) -> UInt64 {
        guard numer != denom, denom != 0 else { return ticks }
        let product = ticks.multipliedFullWidth(by: UInt64(numer))
        guard product.high < UInt64(denom) else { return .max }
        return UInt64(denom).dividingFullWidth(product).quotient
    }
}

/// `host_statistics(HOST_CPU_LOAD_INFO)` tick counters summed over all cores. They are 32-bit and wrap.
public struct CPULoadTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// Busy share of all cores since `previous`, 0–100. nil when no tick elapsed.
    public func busyPercent(since previous: CPULoadTicks) -> Double? {
        let busy = UInt64(user &- previous.user) + UInt64(system &- previous.system) + UInt64(nice &- previous.nice)
        let total = busy + UInt64(idle &- previous.idle)
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

public enum MemoryAccounting {
    /// Activity Monitor's "Memory Used": app memory (internal − purgeable) + wired + compressed,
    /// from `host_statistics64(HOST_VM_INFO64)` page counts.
    public static func usedBytes(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                                 compressorPages: UInt64, pageSize: UInt64) -> UInt64 {
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (appPages + wiredPages + compressorPages) * pageSize
    }
}

/// One process of a workspace as read by the Mac app's scanner (`proc_pid_rusage`).
public struct ProcessUsageSample: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    /// Process start in the nanosecond clock passed as `now` to `ProcessUsageAccountant.update`.
    /// Together with `pid` it identifies the process across scans (pids are reused).
    public var startTime: UInt64
    /// Workspace the process belongs to.
    public var group: String
    /// User + system CPU time of the process, ns.
    public var cpuTime: UInt64
    /// User + system CPU time of the terminated children it has reaped (which include their own reaped
    /// descendants), ns.
    public var childCPUTime: UInt64
    /// Physical footprint ("Memory" in Activity Monitor), bytes.
    public var memoryBytes: UInt64

    public init(pid: Int32, parentPID: Int32, startTime: UInt64, group: String, cpuTime: UInt64,
                childCPUTime: UInt64 = 0, memoryBytes: UInt64 = 0) {
        self.pid = pid
        self.parentPID = parentPID
        self.startTime = startTime
        self.group = group
        self.cpuTime = cpuTime
        self.childCPUTime = childCPUTime
        self.memoryBytes = memoryBytes
    }
}

/// Usage of one workspace's processes.
public struct ResourceUsage: Equatable, Sendable {
    /// Activity Monitor style: 100 = one core busy. nil after the first scan (no baseline yet).
    public var cpuPercent: Double?
    public var memoryBytes: UInt64
    public var processCount: Int

    public init(cpuPercent: Double? = nil, memoryBytes: UInt64 = 0, processCount: Int = 0) {
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.processCount = processCount
    }
}

/// Turns successive process scans into per-workspace CPU % and memory.
///
/// CPU of a workspace over a scan interval = growth of each live process's own CPU time plus growth of its
/// reaped-children CPU time. The latter catches processes that start and exit between two scans (compilers,
/// git, test runners…), which sampling alone never sees. A process that *was* counted before it exited would
/// then be counted twice (live, and again in its parent's child time), so when a counted process disappears
/// the total counted for it becomes a credit against the next child-time growth of its nearest live ancestor
/// in a workspace (skipping ancestors that disappeared too: their totals include it). A process read during
/// the scan but gone from the final listing counts as gone; its last bit of CPU arrives with its parent's
/// child time. Credits expire after one more scan (the reap may land just after the ancestor was read), so
/// an orphan reaped by launchd never suppresses later readings for long.
///
/// Children that never carried `CMDS_WORKSPACE_ID` (or ran as another user) show up only when reaped; each
/// workspace is capped at all cores busy so such a burst cannot report impossible values.
public struct ProcessUsageAccountant: Sendable {
    private struct Key: Hashable, Sendable {
        var pid: Int32
        var start: UInt64
    }

    private struct Credit: Sendable {
        var amount: UInt64
        /// Scans survived without being used up.
        var age: Int
    }

    /// Per-workspace ceiling: every core busy.
    public let maxPercent: Double
    private var previous: [Key: ProcessUsageSample] = [:]
    private var credits: [Key: Credit] = [:]
    private var previousTime: UInt64?

    public init(cpuCount: Int) {
        maxPercent = Double(max(cpuCount, 1)) * 100
    }

    /// - Parameters:
    ///   - samples: workspace processes read during this scan.
    ///   - alivePIDs: pids listed *after* all samples were read. A sampled process whose pid is missing was
    ///     reaped during the scan.
    ///   - now: scan time, ns (same clock as `ProcessUsageSample.startTime`).
    /// - Returns: usage of every workspace with at least one live process.
    public mutating func update(samples: [ProcessUsageSample], alivePIDs: Set<Int32>, now: UInt64) -> [String: ResourceUsage] {
        var alive: [Key: ProcessUsageSample] = [:]
        var aliveByPID: [Int32: Key] = [:]
        var departed: [Key: ProcessUsageSample] = [:]
        for sample in samples {
            let key = Key(pid: sample.pid, start: sample.startTime)
            if alivePIDs.contains(sample.pid) {
                alive[key] = sample
                aliveByPID[sample.pid] = key
            } else {
                departed[key] = sample
            }
        }
        for (key, sample) in previous where alive[key] == nil && departed[key] == nil {
            departed[key] = sample
        }

        if previousTime != nil, !departed.isEmpty {
            var departedByPID: [Int32: ProcessUsageSample] = [:]
            for sample in departed.values { departedByPID[sample.pid] = sample }
            for (key, sample) in departed {
                // Never counted (started after the last scan): its whole time is new when it shows up in the
                // reaper's child time.
                guard let counted = previous[key],
                      let reaper = Self.liveAncestor(of: sample, alive: aliveByPID, departed: departedByPID) else { continue }
                var credit = credits[reaper] ?? Credit(amount: 0, age: 0)
                credit.amount = credit.amount.addingClamped(counted.cpuTime.addingClamped(counted.childCPUTime))
                credit.age = 0
                credits[reaper] = credit
            }
        }

        var usage: [String: ResourceUsage] = [:]
        var cpuTime: [String: UInt64] = [:]
        for (key, sample) in alive {
            usage[sample.group, default: ResourceUsage()].memoryBytes += sample.memoryBytes
            usage[sample.group, default: ResourceUsage()].processCount += 1
            guard let since = previousTime else { continue }
            var own: UInt64 = 0
            var children: UInt64 = 0
            if let last = previous[key] {
                own = sample.cpuTime.subtractingClamped(last.cpuTime)
                children = sample.childCPUTime.subtractingClamped(last.childCPUTime)
            } else if sample.startTime > since {
                // Started during the interval: all of its time is new.
                own = sample.cpuTime
                children = sample.childCPUTime
            } // else: existed before the last scan but was not sampled then; no baseline.
            if children > 0, var credit = credits[key] {
                let used = min(credit.amount, children)
                children -= used
                credit.amount -= used
                credits[key] = credit
            }
            cpuTime[sample.group, default: 0] = cpuTime[sample.group, default: 0].addingClamped(own.addingClamped(children))
        }

        if let since = previousTime, now > since {
            let interval = Double(now - since)
            for group in usage.keys {
                let percent = Double(cpuTime[group] ?? 0) / interval * 100
                usage[group]?.cpuPercent = min(percent, maxPercent)
            }
        }

        credits = credits.reduce(into: [:]) { kept, entry in
            guard entry.value.amount > 0, entry.value.age == 0, alive[entry.key] != nil else { return }
            kept[entry.key] = Credit(amount: entry.value.amount, age: 1)
        }
        previous = alive
        previousTime = now
        return usage
    }

    /// Nearest live workspace process above `sample`, skipping ancestors that departed too.
    private static func liveAncestor(of sample: ProcessUsageSample, alive: [Int32: Key],
                                     departed: [Int32: ProcessUsageSample]) -> Key? {
        var parent = sample.parentPID
        var visited: Set<Int32> = [sample.pid]
        while visited.insert(parent).inserted {
            if let key = alive[parent] { return key }
            guard let next = departed[parent] else { return nil }
            parent = next.parentPID
        }
        return nil
    }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }

    func addingClamped(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
