// ProcessInspector.swift — System-level process inspection utilities.
// Provides sandbox checking, kernel info (ppid/uid/startTime/arch via single sysctl),
// code signing authority, SHA-256 hashing, sleep assertion detection, and executable path lookup.
// All methods are static — no instance state.

import AppKit
import Darwin
import CryptoKit
import IOKit.pwr_mgt
import Security

final class ProcessInspector {
    private typealias SandboxCheckFunc = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32) -> Int32

    private static let sandboxCheck: SandboxCheckFunc? = {
        // RTLD_DEFAULT is a C macro ((void *)-2) and is unavailable directly in Swift.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return nil }
        return unsafeBitCast(sym, to: SandboxCheckFunc.self)
    }()

    private static let sha256Cache = NSCache<NSString, NSString>()

    static func isSandboxed(pid: pid_t) -> Bool {
        (sandboxCheck?(pid, nil, 0) ?? 0) != 0
    }

    static func sleepPreventingPIDs() -> Set<pid_t> {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let dict = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result = Set<pid_t>()
        for (pidNum, assertions) in dict {
            for a in assertions {
                if let type = a["AssertionTrueType"] as? String ?? a["AssertType"] as? String {
                    if type.contains("Sleep") {
                        result.insert(pid_t(pidNum.int32Value))
                        break
                    }
                }
            }
        }
        return result
    }

    /// All process-level info extracted from a single sysctl(KERN_PROC_PID) call.
    /// All process-level info extracted from a single sysctl(KERN_PROC_PID) call.
    /// Merges what was previously two separate calls (procInfo + archStringByPID).
    struct ProcKernelInfo {
        let ppid: pid_t       // Parent process ID
        let uid: uid_t        // User ID
        let startTime: Double // Unix timestamp of process start
        let arch: String      // "arm64" or "x86_64" (detected via P_TRANSLATED flag)
    }

    /// Single sysctl call per PID — extracts ppid, uid, startTime, and architecture.
    static func kernelInfo(pid: pid_t) -> ProcKernelInfo? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let st = info.kp_proc.p_starttime
        let startSec = Double(st.tv_sec) + Double(st.tv_usec) / 1_000_000.0
        // P_TRANSLATED (0x20000) indicates Rosetta translation (x86_64 on arm64)
        let arch: String
        if info.kp_proc.p_flag & 0x20000 != 0 {
            arch = "x86_64"
        } else {
            #if arch(arm64)
            arch = "arm64"
            #else
            arch = "x86_64"
            #endif
        }
        return ProcKernelInfo(ppid: info.kp_eproc.e_ppid,
                              uid: info.kp_eproc.e_ucred.cr_uid,
                              startTime: startSec,
                              arch: arch)
    }

    static func executablePath(pid: pid_t) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Int(MAXPATHLEN))
        defer { buf.deallocate() }
        let len = proc_pidpath(pid, buf, UInt32(MAXPATHLEN))
        guard len > 0 else { return nil }
        return String(cString: buf)
    }

    static func userName(uid: uid_t) -> String {
        if let pw = getpwuid(uid) { return String(cString: pw.pointee.pw_name) }
        return "\(uid)"
    }

    private static func concurrentMap(_ entries: [ProcEntry], transform: @escaping (ProcEntry) -> ProcEntry) -> [ProcEntry] {
        guard !entries.isEmpty else { return entries }
        let count = entries.count
        let results = UnsafeMutableBufferPointer<ProcEntry>.allocate(capacity: count)
        _ = results.initialize(from: entries)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "hung_detect.concurrent", attributes: .concurrent)
        for i in 0..<count {
            group.enter()
            queue.async {
                results[i] = transform(entries[i])
                group.leave()
            }
        }
        group.wait()
        let output = Array(results)
        results.deallocate()
        return output
    }

    static func addSHA256(_ entries: [ProcEntry], onlyHung: Bool = false) -> [ProcEntry] {
        concurrentMap(entries) { entry in
            if onlyHung && entry.responding != false { return entry }
            if entry.path == "-" { return entry }
            var out = entry
            out.sha256 = sha256OfFile(entry.path)
            return out
        }
    }

    private static func sha256OfFile(_ path: String) -> String {
        if let cached = sha256Cache.object(forKey: path as NSString) {
            return cached as String
        }

        guard let handle = FileHandle(forReadingAtPath: path) else {
            sha256Cache.setObject("-" as NSString, forKey: path as NSString)
            return "-"
        }
        defer { handle.closeFile() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        sha256Cache.setObject(hex as NSString, forKey: path as NSString)
        return hex
    }

    private static let codesignCache = NSCache<NSString, NSString>()

    static func codeSigningAuthority(path: String) -> String {
        guard path != "-" else { return "-" }
        if let cached = codesignCache.object(forKey: path as NSString) {
            return cached as String
        }
        let url = URL(fileURLWithPath: path) as CFURL
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            codesignCache.setObject("unsigned" as NSString, forKey: path as NSString)
            return "unsigned"
        }
        // First pass: basic info (fast) to check adhoc flag
        var basicInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &basicInfo) == errSecSuccess,
              let basicDict = basicInfo as? [String: Any] else {
            codesignCache.setObject("unsigned" as NSString, forKey: path as NSString)
            return "unsigned"
        }
        let flags = basicDict[kSecCodeInfoFlags as String] as? UInt32 ?? 0
        // kSecCodeSignatureAdhoc == 0x0002
        if (flags & 0x0002) != 0 {
            codesignCache.setObject("adhoc" as NSString, forKey: path as NSString)
            return "adhoc"
        }
        // Second pass: full signing info (slower) only for properly signed binaries
        var fullInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &fullInfo) == errSecSuccess,
              let fullDict = fullInfo as? [String: Any],
              let certs = fullDict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leafCert = certs.first else {
            codesignCache.setObject("unsigned" as NSString, forKey: path as NSString)
            return "unsigned"
        }
        let subject = (SecCertificateCopySubjectSummary(leafCert) as String?)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cn = subject?.isEmpty == false ? subject : nil
        let label = signerLabel(cn)
        let result: String
        if let cn = cn, cn.caseInsensitiveCompare(label) != .orderedSame {
            result = "\(label) (\(cn))"
        } else {
            result = label
        }
        codesignCache.setObject(result as NSString, forKey: path as NSString)
        return result
    }

    private static func signerLabel(_ cn: String?) -> String {
        let lower = cn?.lowercased() ?? ""
        if lower.contains("developer id application") || lower.contains("developer id installer") {
            return "Apple Developer ID"
        }
        if lower.contains("3rd party mac developer application") || lower.contains("mac app store") || lower.contains("apple mac os application signing") {
            return "Mac App Store"
        }
        if lower.contains("in-house") || lower.contains("enterprise program") || lower.contains("enterprise") {
            return "Enterprise"
        }
        if lower.contains("software signing") || lower.contains("installer signing") || lower.contains("apple system") {
            return "Apple"
        }
        if lower.contains("apple") && !lower.contains("developer id") {
            return "Apple"
        }
        return cn ?? "Third-Party"
    }

    static func addCodeSign(_ entries: [ProcEntry], onlyHung: Bool = false) -> [ProcEntry] {
        concurrentMap(entries) { entry in
            if onlyHung && entry.responding != false { return entry }
            if entry.path == "-" { return entry }
            var out = entry
            out.codesign = codeSigningAuthority(path: entry.path)
            return out
        }
    }
}
