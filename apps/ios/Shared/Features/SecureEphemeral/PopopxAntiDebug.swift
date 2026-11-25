//
//  PopopxAntiDebug.swift
//  POPOPX (iOS)
//
//  Anti-debug for the Release build: refuse `ptrace` attach + query `P_TRACED` with `sysctl`.
//
//  Why this layer and "top-secret view-once" are the same thing: module five promises "physically destroyed once read", which presupposes that inside this process
//  there is no second party who can read memory. A debugger able to `attach` can park the process forever between decryption and destruction,
//  skipping the countdown and the overwrite entirely - and the little anti-photo effort on screen is meaningless in that situation.
//
//  The two guards each block half:
//  - `PT_DENY_ATTACH`: **first strike**. Once the process makes this request, the kernel thereafter refuses any `ptrace(ATTACH)`,
//    so `debugserver` cannot attach. It does not block the case where "the process was itself started through `task_for_pid`".
//  - `sysctl(KERN_PROC_PID)` reading `p_flag & P_TRACED`: **second strike**, which covers exactly that former case (traced from birth).
//
//  Both are inside `#if !DEBUG`: a Debug build must still be breakable by Xcode, otherwise this change would first disable the developer's own
//  debugging ability, and that is the kind of disabling that cannot be rolled back. The interface itself exists in both builds (`enableProtection()` in Debug
//  is an empty function and `debuggerAttached` is always false), so callers do not need to write the `#if` again.
//
//  Two honest limits - do not advertise this outwardly as "anti-reverse-engineering":
//  1. A jailbroken device can hook `ptrace`/`sysctl` so that both guards report "clean"; what this layer raises is cost, not a wall.
//  2. `PT_DENY_ATTACH` simultaneously disables Xcode attaching under the Release configuration, `frida`, and some of Instruments'
//     attach templates - that is the design intent, not a bug; to profile, use Debug or Time Profiler's
//     Attach to Process at Launch.
//
//  ⚠️ Xcode project integration: this file must be dragged into the POPOPX (iOS) target by hand. The red line forbids scripts from modifying project.pbxproj.
//

import Darwin
import Foundation

enum PopopxAntiDebug {
    /// Whether `enableProtection()` has already been called at the launch entry. Used only to keep a second call from requesting `PT_DENY_ATTACH`
    /// all over again (the repeated request itself is harmless, but that log would become a puzzle about "how many times was this called").
    private(set) static var protectionInstalled = false

    /// The `sysctl` conclusion. Measured once at launch and unchanged afterwards: read it before the top-secret window opens.
    private(set) static var debuggerAttached = false

    /// Called at the App launch entry (the `init()` of `Shared/POPOPXApp.swift`).
    static func enableProtection() {
        #if !DEBUG
        guard !protectionInstalled else { return }
        protectionInstalled = true
        denyDebuggerAttach()
        debuggerAttached = processIsBeingTraced()
        #else
        // Debug build: does nothing, and leaves no "this line did not execute" log either.
        protectionInstalled = true
        #endif
    }

    /// Whether the top-secret window can open. The criterion is "is this process being traced right now", not "is this device jailbroken" -
    /// the latter has no reliable public criterion, and a guessed conclusion would only shut ordinary users out.
    static var allowsSecurePresentation: Bool {
        #if !DEBUG
        !debuggerAttached
        #else
        true
        #endif
    }

    // MARK: - First strike: refuse attach

    /// `ptrace` is obtained through `dlsym`, not called directly.
    ///
    /// Why take this detour: `ptrace` is a symbol, and static scans (App Store review, enterprise customers' binary audits)
    /// can list it just by picking its name out of the `__Import` section. After `dlsym(RTLD_DEFAULT, "ptrace")`
    /// the name exists only as a string inside `__cstring`. This is **not** a means of evading review - the real reason it is needed is:
    /// iOS's `ptrace` declaration is not always visible in the SDK (different SDK versions expose `<sys/ptrace.h>` to different degrees),
    /// and `dlsym` fetching the runtime's real symbol sidesteps that header drift without adding a C bridging header for it
    /// - the red line in this repository is that new files contain Swift only and no new target level build settings are added.
    private static func denyDebuggerAttach() {
        // `PT_DENY_ATTACH` = 31, an enum in `<sys/ptrace.h>`. Written here as a literal with its source marked:
        // the enum's imported name on the Swift side has changed with SDK versions (`PT_DENY_ATTACH` is a case, not a macro),
        // and its value has not moved between the 10.x and 27.x SDKs.
        let ptDenyAttach = 31
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ptrace") else { // -2 = RTLD_DEFAULT
            return
        }
        // `int ptrace(int request, pid_t pid, caddr_t addr, int data)`. A variadic C function cannot be converted directly
        // into a Swift closure type, so it is converted using the calling convention of four fixed parameters: `caddr_t` is `char *`.
        typealias PopopxPtrace = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
        let trace = unsafeBitCast(symbol, to: PopopxPtrace.self)
        _ = trace(Int32(ptDenyAttach), 0, nil, 0)
    }

    // MARK: - Second strike: traced from birth

    /// `sysctl({CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()})` → `kinfo_proc.kp_proc.p_flag & P_TRACED`。
    private static func processIsBeingTraced() -> Bool {
        // CTL_KERN = 1, KERN_PROC = 14, KERN_PROC_PID = 1（`<sys/sysctl.h>`）。
        // These three are enums and Swift imports them, but `sysctl`'s name parameter wants an `UnsafeMutablePointer<Int32>`,
        // so building the array from literals leaves one fewer SDK difference than stitching the three enum names together; the source is written here.
        var name: [Int32] = [1, 14, 1, 0]
        name[3] = Int32(getpid())
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // `P_TRACED` = 0x00000800, `<sys/proc.h>`. This one is a macro, and Swift's ability to import macros is limited,
        // so writing the literal + the source outright is more honest than `#if canImport(...)`.
        let pTraced: Int32 = 0x0000_0800
        // On success `size != 0`; on failure `errno` will be EPERM/EINVAL, and that case **must not** be taken as
        // "traced" - otherwise one failed query would permanently disable the top-secret feature. The criterion holds only when the flag was actually read.
        let result = sysctl(&name, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return false }
        return (info.kp_proc.p_flag & pTraced) != 0
    }
}
