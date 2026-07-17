import AppKit
import SwiftUI
import TaskDeckCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.model?.flushEverything()
        }
    }
}

@main
struct TaskDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear { AppDelegate.model = model }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("新任務") { model.newTask() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("放大") { model.zoomIn() }
                    .keyboardShortcut("=", modifiers: .command)
                Button("縮小") { model.zoomOut() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("實際大小") { model.zoomReset() }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }

        WindowGroup("任務", id: "task", for: String.self) { $slug in
            if let slug {
                PopoutRoot(slug: slug)
                    .environmentObject(model)
                    .onAppear { AppDelegate.model = model }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 230

    var body: some View {
        GeometryReader { geo in
            let w = CGFloat(min(max(150, sidebarWidth), 420))
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: w)
                ColumnDividerHandle(width: $sidebarWidth, total: geo.size.width, sign: +1)
                Group {
                    if let slug = model.selection {
                        TaskDetailView(slug: slug)
                            .environmentObject(model.session(slug))
                            .id(slug)
                    } else {
                        EmptyStateView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .glassWindow()
        .preferredColorScheme(.dark)
    }
}

struct PopoutRoot: View {
    @EnvironmentObject var model: AppModel
    let slug: String

    var body: some View {
        TaskDetailView(slug: slug)
            .environmentObject(model.session(slug))
            .navigationTitle(slug)
            .frame(minWidth: 800, minHeight: 480)
            .glassWindow()
            .preferredColorScheme(.dark)
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 42))
                .foregroundStyle(.quaternary)
            Text("選一個任務，或建立新任務")
                .foregroundStyle(.secondary)
            Button("新任務（⇧⌘N）") { model.newTask() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
    }
}
