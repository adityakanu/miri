#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Parent/child relationships between processes.
///
/// This exists to answer one question exactly: *is the agent session I found in
/// the process table running inside the application the user is looking at?*
///
/// Window titles and working-directory string matching both guess. Ancestry
/// does not: if Terminal is frontmost and `codex` was launched from a shell in
/// one of its tabs, the Codex process has Terminal as an ancestor. That is a
/// fact the kernel already knows, so foreground routing can be exact rather
/// than heuristic.
///
/// The graph walk is pure so it can be tested without spawning processes; only
/// `current()` touches libproc.
public enum ProcessAncestry {
    /// Every process on the machine mapped to its parent.
    public typealias ParentMap = [pid_t: pid_t]

    /// True when `pid` is `ancestor` itself or is reachable from it by
    /// following parent links upward.
    ///
    /// Walks child → parent rather than parent → children: each process has
    /// exactly one parent, so the walk is O(depth) instead of O(processes), and
    /// a cycle in a malformed map cannot loop forever because the visited set
    /// terminates it.
    public static func isDescendant(_ pid: pid_t, of ancestor: pid_t, in parents: ParentMap) -> Bool {
        if pid == ancestor { return true }
        var current = pid
        var visited: Set<pid_t> = [pid]
        while let parent = parents[current], parent > 0 {
            if parent == ancestor { return true }
            guard visited.insert(parent).inserted else { return false }
            current = parent
        }
        return false
    }

    #if canImport(Darwin)
    /// Reads the live parent map from libproc.
    ///
    /// Reads *every* process, not just the agents: the chain from a `codex`
    /// process up to Terminal runs through intermediate shells, so a partial
    /// map breaks the walk at the first process it does not contain.
    ///
    /// `PROC_PIDTBSDINFO` on a same-user process needs no entitlement and no
    /// permission prompt, and the call is read-only: nothing here signals,
    /// writes to, or attaches to another process.
    public static func current(pids: [pid_t]? = nil) -> ParentMap {
        var parents: ParentMap = [:]
        for pid in pids ?? allProcessIdentifiers() {
            var info = proc_bsdinfo()
            let size = proc_pidinfo(
                pid, PROC_PIDTBSDINFO, 0, &info,
                Int32(MemoryLayout<proc_bsdinfo>.size)
            )
            guard size > 0 else { continue }
            parents[pid] = pid_t(info.pbi_ppid)
        }
        return parents
    }

    private static func allProcessIdentifiers() -> [pid_t] {
        let size = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard size > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(size) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, size)
        guard written > 0 else { return [] }
        return pids.prefix(Int(written) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }
    #endif
}
