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

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            if let slug = model.selection {
                TaskDetailView(slug: slug)
                    .environmentObject(model.session(slug))
                    .id(slug)
            } else {
                EmptyStateView()
            }
        }
        .frame(minWidth: 980, minHeight: 600)
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
