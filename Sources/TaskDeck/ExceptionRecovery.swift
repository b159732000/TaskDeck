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
        let cls: AnyClass = type(of: app)
        let selector = #selector(NSApplication.reportException(_:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Report = @convention(c) (NSApplication, Selector, NSException) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Report.self)
        let replacement: @convention(block) (NSApplication, NSException) -> Void = { app, exception in
            original(app, selector, exception)
            if Thread.isMainThread {
                MainActor.assumeIsolated { handle(exception) }
            }
        }
        let imp = imp_implementationWithBlock(replacement)
        // An override on NSApp's own class; NSApplication's method is only
        // replaced in place when that class already overrides it itself.
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(method)) {
            method_setImplementation(method, imp)
        }
    }

    private static func handle(_ exception: NSException) {
        guard !relaunching else { return }
        let now = Date()
        let defaults = UserDefaults.standard
        let lastRelaunch = defaults.object(forKey: lastRelaunchKey) as? Date
        let relaunch = ExceptionRecoveryRules.shouldRelaunch(
            launchedAt: launchedAt, lastRelaunch: lastRelaunch, now: now)
        var decision = "up \(Int(now.timeIntervalSince(launchedAt))) s"
        if let lastRelaunch {
            decision += ", last auto relaunch \(Int(now.timeIntervalSince(lastRelaunch))) s ago"
        }
        decision += relaunch ? " — relaunching" : " — NOT relaunching (too soon)"
        record(exception, at: now, decision: decision)
        guard relaunch else { return notifyStuck() }

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

    /// No relaunch this time, and the window may well be frozen — so say it
    /// outside the window.
    private static func notifyStuck() {
        let content = UNMutableNotificationContent()
        content.title = "JamesDesk 畫面可能卡住了"
        content.body = "終端都還在背景照常執行。從 Dock 結束 JamesDesk 再打開即可，終端不會中斷。"
        let request = UNNotificationRequest(identifier: "exception-recovery",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("TaskDeck: exception notification failed: \(error)") }
        }
    }
}
