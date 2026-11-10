import Darwin
import Foundation
import WorkTimerCore

/// Tells what the processes behind agents' background tasks are doing. A task's
/// processes are the ones writing to its output file, plus their children.
///
/// At each check, a task worked if they used the CPU or wrote to any file since
/// the previous check. Writing catches work that runs elsewhere — in a
/// container, a VM, over SSH — since it streams its progress back; a server
/// waiting for requests does neither. `TaskActivityTracker` decides from there.
/// Only reads your own processes, so it needs no permissions.
final class TaskProbe {
    /// Average CPU use, in cores, from which a task counts as working.
    private static let workingCores = 0.1

    /// Each task's CPU time at the previous check, to measure use since then.
    private var cpu: [String: TimeInterval] = [:]
    private var lastCheck: Date?
    private var tracker = TaskActivityTracker()

    /// Converts the task-info CPU times (Mach ticks on Apple silicon) to seconds.
    private static let secondsPerTick: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    func activity(of tasks: [BackgroundTask], now: Date = Date()) -> [String: TaskActivity] {
        var taskByFile: [String: String] = [:]
        for task in tasks { if let file = task.outputFile { taskByFile[file] = task.id } }
        defer { lastCheck = now }
        tracker.keep(only: Set(taskByFile.values))
        cpu = cpu.filter { taskByFile.values.contains($0.key) }
        guard !taskByFile.isEmpty else { return [:] }

        var children: [pid_t: [pid_t]] = [:]
        var writers: [String: [pid_t]] = [:]
        for pid in Self.allProcesses() {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { continue }
            children[pid_t(info.pbi_ppid), default: []].append(pid)
            for fd: Int32 in [1, 2] {
                if let path = Self.path(of: fd, in: pid), let id = taskByFile[path] {
                    writers[id, default: []].append(pid)
                    break
                }
            }
        }

        var result: [String: TaskActivity] = [:]
        for id in Set(taskByFile.values) {
            guard let roots = writers[id] else {
                cpu[id] = nil
                result[id] = tracker.update(id, worked: nil, at: now)
                continue
            }
            var tree = Set<pid_t>()
            var stack = roots
            while let pid = stack.popLast() {
                if tree.insert(pid).inserted { stack += children[pid] ?? [] }
            }
            let total = tree.reduce(0) { $0 + Self.cpuTime(of: $1) }
            var worked = false
            // Only change seen between two checks counts: the first look has
            // nothing to compare with, and what happened before it is startup.
            if let before = cpu[id], let last = lastCheck, now > last {
                let cores = max(0, total - before) / now.timeIntervalSince(last)
                let wrote = tree.contains { pid in Self.lastWrite(by: pid).map { $0 > last } ?? false }
                worked = cores >= Self.workingCores || wrote
            }
            cpu[id] = total
            result[id] = tracker.update(id, worked: worked, at: now)
        }
        return result
    }

    // MARK: - libproc

    private static func allProcesses() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(max(0, Int(found))))
    }

    private static func path(of fd: Int32, in pid: pid_t) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        return withUnsafeBytes(of: info.pvip.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// When the process last changed a regular file it has open for writing.
    private static func lastWrite(by pid: pid_t) -> Date? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard filled > 0 else { return nil }
        var latest: Date?
        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, infoSize) == infoSize,
                  info.pfi.fi_openflags & UInt32(FWRITE) != 0,
                  info.pvip.vip_vi.vi_stat.vst_mode & S_IFMT == S_IFREG else { continue }
            let stat = info.pvip.vip_vi.vi_stat
            let written = Date(timeIntervalSince1970: TimeInterval(stat.vst_mtime) + TimeInterval(stat.vst_mtimensec) / 1e9)
            latest = max(latest ?? written, written)
        }
        return latest
    }

    private static func cpuTime(of pid: pid_t) -> TimeInterval {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return 0 }
        return Double(info.pti_total_user + info.pti_total_system) * secondsPerTick
    }
}
