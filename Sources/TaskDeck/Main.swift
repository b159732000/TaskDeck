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
                Menu("外觀") {
                    Menu("強調色") {
                        ForEach(Theme.accentPresets, id: \.hex) { preset in
                            Button((UInt32(model.accentHex) == preset.hex ? "✓ " : "") + preset.name) {
                                model.accentHex = Int(preset.hex)
                            }
                        }
                    }
                    Menu("底色") {
                        ForEach(Array(Theme.bgPresets.enumerated()), id: \.offset) { i, preset in
                            Button((model.bgPresetIndex == i ? "✓ " : "") + preset.name) {
                                model.bgPresetIndex = i
                            }
                        }
                    }
                    Divider()
                    SettingsLink { Text("外觀設定（透明度／明暗）…") }
                }
            }
        }

        WindowGroup("任務", id: "task", for: String.self) { $slug in
            if let slug {
                PopoutRoot(slug: slug)
                    .environmentObject(model)
                    .onAppear { AppDelegate.model = model }
            }
        }

        Settings {
            AppearanceSettingsView()
                .environmentObject(model)
        }
    }
}

/// ⌘, — base-appearance tuning: bg hue preset, glass opacity, brightness,
/// accent. All persisted; effects are live (Theme reads mirrored statics,
/// AppModel's @Published triggers the re-render).
struct AppearanceSettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("底色", selection: $model.bgPresetIndex) {
                ForEach(Array(Theme.bgPresets.enumerated()), id: \.offset) { i, preset in
                    Text(preset.name).tag(i)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $model.bgOpacityBoost, in: 0 ... 1) {
                    Text("不透明度")
                }
                Text(model.bgOpacityBoost < 0.02
                    ? "玻璃感（預設）——桌布透進來"
                    : "\(Int(model.bgOpacityBoost * 100))%（越高越實心）")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Slider(value: $model.bgBrightness, in: -0.25 ... 0.25) {
                    Text("明暗")
                }
                Text(String(format: "%+.0f%%", model.bgBrightness * 100))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            LabeledContent("強調色") {
                HStack(spacing: 6) {
                    ForEach(Theme.accentPresets, id: \.hex) { preset in
                        Button {
                            model.accentHex = Int(preset.hex)
                        } label: {
                            Circle()
                                .fill(Color(hex: preset.hex))
                                .frame(width: 16, height: 16)
                                .overlay(
                                    Circle().stroke(.white.opacity(
                                        UInt32(model.accentHex) == preset.hex ? 0.9 : 0),
                                    lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(preset.name)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 400)
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
        // Root tint must reach the very top of the window: SwiftUI keeps
        // per-view backgrounds inside the safe area, so without this the
        // titlebar strip is bare behind-window blur — a black-looking band
        // over a dark desktop (the "opaque titlebar" that survived every
        // titlebar-view sweep).
        .background(Theme.windowBG.ignoresSafeArea())
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
            .background(Theme.windowBG.ignoresSafeArea()) // see ContentView
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
