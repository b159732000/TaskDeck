import Darwin
import Foundation

/// One process, as the kernel reports it.
public struct ProcessRecord: Equatable, Sendable {
    public let pid: Int32
    public let parent: Int32
    public let group: Int32
    /// Foreground process group of this process's controlling terminal — the
    /// group Ctrl-C would hit, i.e. what the terminal is running right now.
    /// -1 when the process has no terminal.
    public let terminalForegroundGroup: Int32
    /// Kernel process name, truncated to 16 characters. Only a hint: Claude
    /// Code renames itself to its version string ("2.1.274"), so identity has
    /// to come from the argument vector.
    public let name: String
    public let started: Date

    public init(pid: Int32, parent: Int32, group: Int32, terminalForegroundGroup: Int32,
                name: String, started: Date) {
        self.pid = pid
        self.parent = parent
        self.group = group
        self.terminalForegroundGroup = terminalForegroundGroup
        self.name = name
        self.started = started
    }
}

/// Reading the live process table. One `sysctl` returns every process at once
/// (~1 ms for ~1000 processes), which is what makes "what is each pane running"
/// cheap enough to sample continuously: the alternative — asking per pane, or
/// spawning `ps` — costs 30-40 ms and a process launch each time.
///
/// Everything here is a plain kernel read; nothing is signalled or modified.
public enum ProcessTable {
    public static func snapshot() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var probe = 0
        guard sysctl(&mib, 4, nil, &probe, nil, 0) == 0, probe > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between sizing and reading; ask for a margin, and
        // retry once on ENOMEM rather than returning a truncated world.
        for attempt in 0 ..< 2 {
            let capacity = probe + probe / 8 + stride * (attempt + 1)
            var buffer = [UInt8](repeating: 0, count: capacity)
            var actual = capacity
            let rc = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, 4, raw.baseAddress, &actual, nil, 0)
            }
            if rc != 0 {
                guard errno == ENOMEM else { return [] }
                probe = capacity
                continue
            }
            var out: [ProcessRecord] = []
            out.reserveCapacity(actual / stride)
            buffer.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                for index in 0 ..< (actual / stride) {
                    let entry = base.advanced(by: index * stride)
                        .loadUnaligned(as: kinfo_proc.self)
                    let time = entry.kp_proc.p_un.__p_starttime
                    out.append(ProcessRecord(
                        pid: entry.kp_proc.p_pid,
                        parent: entry.kp_eproc.e_ppid,
                        group: entry.kp_eproc.e_pgid,
                        terminalForegroundGroup: entry.kp_eproc.e_tpgid,
                        name: name(of: entry.kp_proc.p_comm),
                        started: Date(timeIntervalSince1970: Double(time.tv_sec)
                            + Double(time.tv_usec) / 1_000_000)
                    ))
                }
            }
            return out
        }
        return []
    }

    /// Full argument vector, or [] when the process is gone / not ours.
    /// Argv never changes for a live pid, so callers should cache it.
    public static func commandLine(_ pid: Int32) -> [String] {
        guard pid > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ raw in
            sysctl(&mib, 3, raw.baseAddress, &size, nil, 0)
        }) == 0, size > MemoryLayout<Int32>.size else { return [] }

        // Layout: argc, exec path, then argc NUL-terminated arguments.
        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }
        var cursor = MemoryLayout<Int32>.size
        func next() -> String? {
            guard cursor < size else { return nil }
            let start = cursor
            while cursor < size, buffer[cursor] != 0 { cursor += 1 }
            let text = String(decoding: buffer[start ..< cursor], as: UTF8.self)
            while cursor < size, buffer[cursor] == 0 { cursor += 1 }
            return text
        }
        _ = next() // exec path, repeated as argv[0] below
        var argv: [String] = []
        while argv.count < Int(argc), let argument = next() { argv.append(argument) }
        return argv
    }

    /// Resident memory, or 0 when the process is gone.
    public static func residentBytes(_ pid: Int32) -> UInt64 {
        guard pid > 0 else { return 0 }
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, size)
        }
        return rc == size ? info.pti_resident_size : 0
    }

    private static func name(of comm: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                      CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                      CChar)) -> String {
        var value = comm
        return withUnsafeBytes(of: &value) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
