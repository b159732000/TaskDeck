import AppKit
import ObjectiveC
import TaskDeckCore
import UserNotifications

/// AppKit catches an Objective-C exception that escapes the run loop, logs
/// it (`-[NSApplication reportException:]`) and carries on. When it escapes
/// from SwiftUI's update flush — twice so far (10-26, 10-29): an
/// NSRangeException out of the sidebar List's NSOutlineView row diff —
/// SwiftUI's update bookkeeping is left half-done and the window never
/// redraws again: a frozen GUI whose main thread sits idle. The terminals
/// all live in taskdeckd, so what a person does by hand (quit, reopen) is
/// safe to do automatically: record the exception, flush, relaunch, exit.
///
/// SwiftUI runs its own NSApplication subclass and ignores NSPrincipalClass,
/// so the hook wraps `reportException:` on whatever class NSApp really is.
///
/// An exception thrown during layout never reaches `reportException:`:
/// AppKit catches it in `_NSViewLayout` and calls
/// `+[NSApplication _crashOnException:]`, which traps (nor does
/// NSSetUncaughtExceptionHandler fire — both checked in an offscreen
/// harness). On 11-17 the sidebar's row diff threw from inside
/// NSHostingView.layout and the GUI simply vanished: nothing logged, no
/// relaunch. So that class method is wrapped too, into the same record →
/// relaunch path; only when the relaunch rules say no does the trap go on.
@MainActor
enum ExceptionRecovery {
    private static var launchedAt = Date()
    private static var installed = false
    private static var relaunching = false
    private static let lastRelaunchKey = "lastExceptionRelaunch"

    /// Call once NSApp exists (applicationWillFinishLaunching).
    static func install() {
        guard !installed, let app = NSApp else { return }
        installed = true
        launchedAt = Date()
        installCrashHook()
        let cls: AnyClass = type(of: app)
        let selector = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Report = @convention(c) (NSApplication, Selector, NSException) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Report.self)
        let replacement: @convention(block) (NSApplication, NSException) -> Void = { app, exception in
            original(app, selector, exception)
            if Thread.isMainThread {
                MainActor.assumeIsolated { handle(exception, fatal: false) }
            }
        }
        let imp = imp_implementationWithBlock(replacement)
        // An override on NSApp's own class; NSApplication's method is only
        // replaced in place when that class already overrides it itself.
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }

    /// Wraps the private `+[NSApplication _crashOnException:]` (see the type
    /// comment). Replaced in place on NSApplication's metaclass, so a call
    /// through the SwiftUI subclass resolves to it as well. If a future macOS
    /// drops the selector this is a no-op and layout exceptions crash as
    /// before.
    private static func installCrashHook() {
        guard let meta = object_getClass(NSApplication.self) else { return }
        let selector = NSSelectorFromString("_crashOnException:")
        guard let method = class_getInstanceMethod(meta, selector) else { return }
        typealias Crash = @convention(c) (AnyObject, Selector, NSException) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Crash.self)
        let replacement: @convention(block) (AnyObject, NSException) -> Void = { cls, exception in
            if Thread.isMainThread {
                // Relaunching ends in exit(0) and never comes back here.
                MainActor.assumeIsolated { handle(exception, fatal: true) }
            }
            original(cls, selector, exception)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
    }

    /// `fatal`: AppKit is about to kill the GUI (layout path) rather than
    /// carry on with a possibly frozen window (reportException path).
    private static func handle(_ exception: NSException, fatal: Bool) {
        guard !relaunching else { return }
        let now = Date()
        let defaults = UserDefaults.standard
        let lastRelaunch = defaults.object(forKey: lastRelaunchKey) as? Date
        let relaunch = ExceptionRecoveryRules.shouldRelaunch(
            launchedAt: launchedAt, lastRelaunch: lastRelaunch, now: now)
        var decision = fatal ? "fatal (thrown in layout), up " : "up "
        decision += "\(Int(now.timeIntervalSince(launchedAt))) s"
        if let lastRelaunch {
            decision += ", last auto relaunch \(Int(now.timeIntervalSince(lastRelaunch))) s ago"
        }
        decision += relaunch ? " — relaunching" : " — NOT relaunching (too soon)"
        record(exception, at: now, decision: decision)
        guard relaunch else { return notifyStuck(fatal: fatal) }

        relaunching = true
        defaults.set(now, forKey: lastRelaunchKey)
        defaults.synchronize() // exit(0) follows; don't leave the stamp in flight
        // Spawned before the flush, so a second failure on the way out still
        // ends in a relaunch: the shell only waits for this pid to be gone.
        spawnRelauncher(inBackground: !(NSApp?.isActive ?? false))
        AppDelegate.model?.flushEverything()
        exit(0)
    }

    /// `open` on a still-running app only activates it, so a detached shell
    /// waits for this pid to be gone first. `-g` keeps a relaunch that
    /// happens while you are in another app from stealing focus.
    private static func spawnRelauncher(inBackground: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "
                + (inBackground ? "-g " : "") + "\"$2\"",
            "taskdeck-relaunch", String(getpid()), Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            NSLog("TaskDeck: relaunch helper failed to start: \(error)")
        }
    }

    /// The unified log redacts the reason (`<private>`); this file keeps it,
    /// with the full stack, for working out the trigger later.
    private static func record(_ exception: NSException, at now: Date, decision: String) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var text = "[\(stamp.string(from: now))] \(exception.name.rawValue): "
            + "\(exception.reason ?? "(no reason)")\n  \(decision)\n"
        if let info = exception.userInfo, !info.isEmpty {
            text += "  userInfo: \(info)\n"
        }
        text += exception.callStackSymbols.map { "  \($0)\n" }.joined()
        let url = Paths.appSupport.appendingPathComponent("exceptions.log")
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// No relaunch this time, and the window may well be frozen (or, when
    /// `fatal`, about to be gone) — so say it outside the window.
    private static func notifyStuck(fatal: Bool) {
        let content = UNMutableNotificationContent()
        if fatal {
            content.title = "JamesDesk 剛剛閃退了"
            content.body = "終端都還在背景照常執行。從 Dock 打開 JamesDesk 即可，終端不會中斷。"
        } else {
            content.title = "JamesDesk 畫面可能卡住了"
            content.body = "終端都還在背景照常執行。從 Dock 結束 JamesDesk 再打開即可，終端不會中斷。"
        }
        let request = UNNotificationRequest(identifier: "exception-recovery",
                                            content: content, trigger: nil)
        // The fatal path traps as soon as this returns: hold on (briefly)
        // until the request is handed over. The completion runs on a
        // background queue, so waiting on main cannot deadlock it.
        let handedOver = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("TaskDeck: exception notification failed: \(error)") }
            handedOver.signal()
        }
        if fatal { _ = handedOver.wait(timeout: .now() + 1.5) }
    }
}
