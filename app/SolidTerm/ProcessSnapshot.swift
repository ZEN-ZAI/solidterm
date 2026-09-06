// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Zen Kiattikhunnawong

// ProcessSnapshot — read another process's parent/child links and argv
// straight from the kernel, using nothing but a pid.
//
// This exists so `SessionJournal` can record what each window was doing
// WITHOUT touching AppKit or the main thread. Every fact the journal
// persists (cwd, foreground command) is derived here from a pid, which is
// what lets the sampler keep running while the main thread is wedged —
// the failure mode that motivated the journal in the first place.
//
// Two kernel reads:
//   - `KERN_PROC_ALL`  → one pass builds the whole ppid → [pid] map, so
//     sampling N windows still costs a single syscall.
//   - `KERN_PROCARGS2` → the argv blob for one pid.
//
// The `proc_pidinfo` cwd read lives here too, so everything pid-derived
// sits behind one type. `MetalRenderer.cwdForPid` now forwards to it
// rather than keeping a second copy.

import Darwin
import Foundation

enum ProcessSnapshot {

    /// `KERN_PROCARGS2` is not surfaced by the Darwin overlay in every SDK,
    /// so pin the value from `<sys/sysctl.h>` locally rather than relying on
    /// it being importable.
    private static let kernProcArgs2: Int32 = 49

    /// One child process, with enough info to pick the newest.
    struct Child {
        let pid: pid_t
        /// `p_starttime` as a Unix timestamp — used to pick the most
        /// recently spawned child (see `newestChild`).
        let startedAt: Double
    }

    // MARK: - cwd

    /// macOS `proc_pidinfo(PROC_PIDVNODEPATHINFO)` wrapper. The struct is
    /// laid out as two `vnode_info_path` blocks (proc + cwd); we only want
    /// the cwd path. Returns nil on any libproc failure.
    static func cwd(forPid pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let n = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, $0, Int32(size))
        }
        guard n == Int32(size) else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(validatingUTF8: $0)
            }
        }
    }

    // MARK: - Process table

    /// Snapshot the whole process table as `ppid → children`.
    ///
    /// Returns an empty map on any sysctl failure — callers treat that as
    /// "no command known" and keep the previously journalled value, which
    /// degrades correctly (a stale command is better than dropping one).
    static func childMap() -> [pid_t: [Child]] {
        guard let procs = allProcesses() else { return [:] }
        var map: [pid_t: [Child]] = [:]
        for p in procs {
            let pid = p.kp_proc.p_pid
            let ppid = p.kp_eproc.e_ppid
            guard pid > 0, ppid > 0 else { continue }
            let tv = p.kp_proc.p_un.__p_starttime
            let started = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
            map[ppid, default: []].append(Child(pid: pid, startedAt: started))
        }
        return map
    }

    /// The most recently started direct child of `pid`.
    ///
    /// Approximates "what is in the foreground". A login shell running one
    /// program has exactly one child, which is the overwhelmingly common
    /// case here. It is an approximation: with several concurrent children
    /// (background jobs) the newest wins, which is not necessarily the one
    /// holding the tty. Reading the real foreground pgid would need
    /// `tcgetpgrp` on the PTY master fd, which lives in Rust and is not
    /// exposed across the FFI — not worth widening the bridge for a
    /// convenience feature.
    static func newestChild(of pid: pid_t, in map: [pid_t: [Child]]) -> pid_t? {
        guard let kids = map[pid], !kids.isEmpty else { return nil }
        return kids.max(by: { $0.startedAt < $1.startedAt })?.pid
    }

    private static func allProcesses() -> [kinfo_proc]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        // The table can grow between the sizing call and the read, so retry
        // a bounded number of times on ENOMEM instead of looping forever.
        for _ in 0..<4 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
                return nil
            }
            let capacity = size / MemoryLayout<kinfo_proc>.stride
            var buf = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var readSize = size
            let rc = buf.withUnsafeMutableBytes { raw -> Int32 in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &readSize, nil, 0)
            }
            if rc == 0 {
                return Array(buf.prefix(readSize / MemoryLayout<kinfo_proc>.stride))
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }

    // MARK: - argv

    /// The full command line of `pid`, space-joined, or `nil` when the
    /// kernel refuses (process gone, or owned by another user).
    ///
    /// `KERN_PROCARGS2` returns a packed blob:
    ///
    ///     [ argc: Int32 ][ exec_path\0 ][ \0 padding ][ argv[0]\0 … argv[argc-1]\0 ][ envp… ]
    ///
    /// We skip the exec path and its alignment padding, then take exactly
    /// `argc` NUL-terminated strings — stopping there is what keeps the
    /// environment (which can hold secrets) out of the journal.
    static func commandLine(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, kernProcArgs2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buf = [UInt8](repeating: 0, count: size)
        var readSize = size
        let rc = buf.withUnsafeMutableBytes { raw -> Int32 in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &readSize, nil, 0)
        }
        guard rc == 0, readSize > MemoryLayout<Int32>.size else { return nil }
        return parseProcArgs2(Array(buf.prefix(readSize)))
    }

    /// Pure parser for a `KERN_PROCARGS2` blob — split out so XCTest can
    /// exercise the layout handling without spawning a process.
    static func parseProcArgs2(_ blob: [UInt8]) -> String? {
        let intSize = MemoryLayout<Int32>.size
        guard blob.count > intSize else { return nil }
        var argc = Int32(0)
        withUnsafeMutableBytes(of: &argc) { dst in
            dst.copyBytes(from: blob[0..<intSize])
        }
        guard argc > 0 else { return nil }

        var i = intSize
        // Skip the exec path.
        while i < blob.count, blob[i] != 0 { i += 1 }
        // Skip the NUL padding that aligns the start of argv.
        while i < blob.count, blob[i] == 0 { i += 1 }

        var args: [String] = []
        var current: [UInt8] = []
        while i < blob.count, args.count < Int(argc) {
            if blob[i] == 0 {
                args.append(String(decoding: current, as: UTF8.self))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(blob[i])
            }
            i += 1
        }
        // A blob that ends without a trailing NUL still yields its last arg.
        if args.count < Int(argc), !current.isEmpty {
            args.append(String(decoding: current, as: UTF8.self))
        }
        let joined = args.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return joined.isEmpty ? nil : joined
    }
}
