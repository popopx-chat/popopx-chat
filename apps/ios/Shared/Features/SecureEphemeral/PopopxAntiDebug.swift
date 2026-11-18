//
//  PopopxAntiDebug.swift
//  POPOPX (iOS)
//
//  Release 包的反调试：拒绝 `ptrace` 附加 + `sysctl` 查 `P_TRACED`。
//
//  为什么这一层和"绝密阅后即焚"是同一件事：模块五承诺"看完就物理销毁"，前提是本进程里
//  没有第二个读得到内存的人。一个能 `attach` 的调试器可以让进程永远停在解密之后、销毁之前，
//  把倒计时和覆写整个跳过——屏幕上那点防拍照努力在这种情况下毫无意义。
//
//  两道各自挡一半：
//  - `PT_DENY_ATTACH`：**先手**。进程一旦提出这个请求，内核从此拒绝任何 `ptrace(ATTACH)`，
//    `debugserver` 挂不上来。它挡不住"进程本来就是被 `task_for_pid` 起来的"这一种。
//  - `sysctl(KERN_PROC_PID)` 读 `p_flag & P_TRACED`：**后手**，正好覆盖前一种（出生即被跟踪）。
//
//  都在 `#if !DEBUG` 里：Debug 构建必须能被 Xcode 断下来，否则这条改动会先废掉开发者自己的
//  调试能力，而它是没法回滚的那种废掉。接口本身两个构建都存在（`enableProtection()` 在 Debug
//  里是空函数、`debuggerAttached` 恒为 false），调用方因此不需要再写一遍 `#if`。
//
//  两个如实的边界，不要对外宣传成"防逆向"：
//  1. 越狱设备可以 hook `ptrace`/`sysctl` 让两道都返回"干净"，这一层抬高的是成本，不是墙。
//  2. `PT_DENY_ATTACH` 会同时让 Release 配置下的 Xcode 附加、`frida`、以及 Instruments 的
//     部分 attach 模板失效——这是设计目的，不是 bug；要 profile 就用 Debug 或 Time Profiler
//     的 Attach to Process at Launch。
//
//  ⚠️ Xcode 工程集成：本文件必须人工拖入 POPOPX (iOS) target。红线禁止脚本修改 project.pbxproj。
//

import Darwin
import Foundation

enum PopopxAntiDebug {
    /// 已在启动入口调用过 `enableProtection()`。只用来防止二次调用把 `PT_DENY_ATTACH`
    /// 再提一遍（重复请求本身无害，但那条日志会变成"到底调了几次"的谜题）。
    private(set) static var protectionInstalled = false

    /// `sysctl` 的结论。启动时测一次，之后不变：绝密窗口打开前读它。
    private(set) static var debuggerAttached = false

    /// 在 App 启动入口调用（`Shared/POPOPXApp.swift` 的 `init()`）。
    static func enableProtection() {
        #if !DEBUG
        guard !protectionInstalled else { return }
        protectionInstalled = true
        denyDebuggerAttach()
        debuggerAttached = processIsBeingTraced()
        #else
        // Debug 构建：什么都不做，也不留一条"这行没执行"的日志。
        protectionInstalled = true
        #endif
    }

    /// 绝密窗口能不能开。判据是"本进程此刻有没有被人跟踪"，不是"这台设备是不是越狱"——
    /// 后者没有可靠的公开判据，猜出来的结论只会把正常用户挡在门外。
    static var allowsSecurePresentation: Bool {
        #if !DEBUG
        !debuggerAttached
        #else
        true
        #endif
    }

    // MARK: - 先手：拒绝 attach

    /// `dlsym` 取 `ptrace`，而不是直接调。
    ///
    /// 为什么绕这一圈：`ptrace` 是一个符号，静态扫描（App Store 审核、企业客户的二进制审计）
    /// 在 `__Import` 段里点到它的名字就能列出来。`dlsym(RTLD_DEFAULT, "ptrace")` 之后，
    /// 这个名字只存在于 `__cstring` 里的一段字符串。这**不是**规避审核的手段——真正需要它的原因是：
    /// iOS 的 `ptrace` 声明在 SDK 里并不总是可见（不同 SDK 版本对 `<sys/ptrace.h>` 的暴露程度不一样），
    /// 而 `dlsym` 拿运行时的真实符号可以绕开这种头文件漂移，不必为此加一个 C 桥接头
    /// ——本仓库的红线是新文件只放 Swift，不新增 target 级构建设置。
    private static func denyDebuggerAttach() {
        // `PT_DENY_ATTACH` = 31，`<sys/ptrace.h>` 里的 enum。这里写成字面量并标出出处：
        // enum 在 Swift 侧的导入名随 SDK 版本变过（`PT_DENY_ATTACH` 是 case，不是宏），
        // 而它的值从 10.x 到 27.x 的 SDK 里没动过。
        let ptDenyAttach = 31
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "ptrace") else { // -2 = RTLD_DEFAULT
            return
        }
        // `int ptrace(int request, pid_t pid, caddr_t addr, int data)`。变参 C 函数不能直接
        // 转成 Swift 的闭包类型，所以按四个定长参数的调用约定转：`caddr_t` 是 `char *`。
        typealias PopopxPtrace = @convention(c) (Int32, Int32, UnsafeMutableRawPointer?, Int32) -> Int32
        let trace = unsafeBitCast(symbol, to: PopopxPtrace.self)
        _ = trace(Int32(ptDenyAttach), 0, nil, 0)
    }

    // MARK: - 后手：出生即被跟踪

    /// `sysctl({CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()})` → `kinfo_proc.kp_proc.p_flag & P_TRACED`。
    private static func processIsBeingTraced() -> Bool {
        // CTL_KERN = 1, KERN_PROC = 14, KERN_PROC_PID = 1（`<sys/sysctl.h>`）。
        // 这三个是 enum，Swift 会导入，但 `sysctl` 的 name 参数要的是 `UnsafeMutablePointer<Int32>`，
        // 用字面量建数组比把三个 enum 名字拼起来少一处 SDK 差异；出处写在这里。
        var name: [Int32] = [1, 14, 1, 0]
        name[3] = Int32(getpid())
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        // `P_TRACED` = 0x00000800，`<sys/proc.h>`。这条是宏，Swift 导入宏的能力有限，
        // 直接写字面量 + 出处比 `#if canImport(...)` 更老实。
        let pTraced: Int32 = 0x0000_0800
        // 成功时 `size != 0`；失败时 `errno` 会是 EPERM/EINVAL，那种情况**不能**当成
        // "被跟踪"——否则一个查询失败就永久禁掉了绝密功能。判据只在真读到 flag 时才成立。
        let result = sysctl(&name, 4, &info, &size, nil, 0)
        guard result == 0, size > 0 else { return false }
        return (info.kp_proc.p_flag & pTraced) != 0
    }
}
