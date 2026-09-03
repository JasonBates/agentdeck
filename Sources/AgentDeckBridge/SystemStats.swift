import Foundation
import Darwin

// MARK: - Machine stats
//
// Sampled on its own timer, never inside a tick. CPU and memory come from Mach calls
// (no subprocess); the agent footprint needs `ps`, which is the only reason this runs
// every few seconds rather than every tick.

struct SystemSnapshot: Encodable {
    var cpuUser: Double
    var cpuSys: Double
    var cpuBusy: Double
    /// Recent busy-CPU samples, oldest first — the sparkline.
    var cpuHistory: [Int]

    var ramUsedGB: Double
    var ramTotalGB: Double
    var ramPercent: Int
    var compressorGB: Double
    var swapUsedGB: Double
    var swapTotalGB: Double
    var swapPercent: Int

    var agentProcs: Int
    var agentCPU: Double
    var agentRSSGB: Double

    var load1: Double
    var cores: Int
}

final class SystemSampler {
    private let lock = NSLock()
    private var snapshot: SystemSnapshot?
    private var history: [Int] = []
    private var lastTicks: (user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32)?

    /// Five minutes of history at a 5s cadence.
    private let historyLimit = 60

    func read() -> SystemSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshot
    }

    func sample() {
        let cpu = sampleCPU()
        let mem = sampleMemory()
        let swap = sampleSwap()
        let agents = sampleAgents()

        var avg = [Double](repeating: 0, count: 3)
        _ = getloadavg(&avg, 3)

        lock.lock()
        if let busy = cpu?.busy {
            history.append(Int(busy.rounded()))
            if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        }
        snapshot = SystemSnapshot(
            cpuUser: cpu?.user ?? 0,
            cpuSys: cpu?.sys ?? 0,
            cpuBusy: cpu?.busy ?? 0,
            cpuHistory: history,
            ramUsedGB: mem.used,
            ramTotalGB: mem.total,
            ramPercent: mem.total > 0 ? Int((mem.used / mem.total * 100).rounded()) : 0,
            compressorGB: mem.compressor,
            swapUsedGB: swap.used,
            swapTotalGB: swap.total,
            swapPercent: swap.total > 0 ? Int((swap.used / swap.total * 100).rounded()) : 0,
            agentProcs: agents.count,
            agentCPU: agents.cpu,
            agentRSSGB: agents.rss,
            load1: (avg[0] * 10).rounded() / 10,
            cores: ProcessInfo.processInfo.activeProcessorCount
        )
        lock.unlock()
    }

    // MARK: Mach counters

    /// CPU is reported as cumulative ticks, so a percentage only exists between two
    /// samples. The first call after launch therefore has nothing to report.
    private func sampleCPU() -> (user: Double, sys: Double, busy: Double)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let now = (user: info.cpu_ticks.0, sys: info.cpu_ticks.1,
                   idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
        defer { lastTicks = now }
        guard let prev = lastTicks else { return nil }

        let dUser = Double(now.user &- prev.user) + Double(now.nice &- prev.nice)
        let dSys = Double(now.sys &- prev.sys)
        let dIdle = Double(now.idle &- prev.idle)
        let total = dUser + dSys + dIdle
        guard total > 0 else { return nil }
        return (dUser / total * 100, dSys / total * 100, (dUser + dSys) / total * 100)
    }

    /// Matches Activity Monitor's notion of "used": active + wired + compressed.
    private func sampleMemory() -> (used: Double, total: Double, compressor: Double) {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, total, 0) }

        let page = Double(vm_kernel_page_size)
        let gb = 1_073_741_824.0
        let compressor = Double(stats.compressor_page_count) * page / gb
        let used = (Double(stats.active_count) + Double(stats.wire_count)) * page / gb + compressor
        return (used, total, compressor)
    }

    private func sampleSwap() -> (used: Double, total: Double) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        let gb = 1_073_741_824.0
        return (Double(usage.xsu_used) / gb, Double(usage.xsu_total) / gb)
    }

    /// The only part that needs a subprocess. Attributes CPU and resident memory to the
    /// agent stack specifically, rather than to the machine as a whole.
    private func sampleAgents() -> (count: Int, cpu: Double, rss: Double) {
        guard let data = try? Shell.run("/bin/ps", ["-Ao", "pcpu,rss,comm"]),
              let text = String(data: data, encoding: .utf8) else { return (0, 0, 0) }

        var count = 0
        var cpu = 0.0
        var rssKB = 0.0
        for line in text.components(separatedBy: .newlines).dropFirst() {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let comm = parts[2...].joined(separator: " ").lowercased()
            guard comm.contains("claude") || comm.contains("codex")
                    || comm.contains("ollama") || comm.hasSuffix("/pi")
                    || comm.contains("herdr")
            else { continue }
            count += 1
            cpu += Double(parts[0]) ?? 0
            rssKB += Double(parts[1]) ?? 0
        }
        return (count, (cpu * 10).rounded() / 10, (rssKB / 1_048_576 * 10).rounded() / 10)
    }
}
