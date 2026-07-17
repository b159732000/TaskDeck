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
        // macOS 26 regression（FB20341654）：某些內容配置下系統會無視
        // titlebarAppearsTransparent 硬畫標題列。正解＝在場景層宣告
        // hiddenTitleBar，讓視窗建立時就無標題列；GlassWindow 的 AppKit
        // sweep 保留當第二道防線。
        .windowStyle(.hiddenTitleBar)
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
        .windowStyle(.hiddenTitleBar) // 同上：macOS 26 標題列回歸的正解

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

            Picker("模糊風格", selection: $model.blurStyleIndex) {
                ForEach(Array(Theme.blurStyles.enumerated()), id: \.offset) { i, style in
                    Text(style.name).tag(i)
                }
            }
            Text("macOS 不開放連續調整模糊半徑，以系統材質分三檔近似。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            sliderRow(title: "透明 ↔ 實心", value: $model.bgOpacityBoost,
                      range: -1 ... 1, defaultValue: 0) {
                if abs(model.bgOpacityBoost) < 0.02 { return "中性（出廠玻璃感）" }
                return model.bgOpacityBoost > 0
                    ? "+\(Int(model.bgOpacityBoost * 100))% 實心"
                    : "\(Int(model.bgOpacityBoost * 100))% 更透（桌布更明顯）"
            }

            sliderRow(title: "明暗", value: $model.bgBrightness,
                      range: -0.25 ... 0.25, defaultValue: 0) {
                String(format: "%+.0f%%", model.bgBrightness * 100)
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

    /// Slider + 「回預設」：精準對回中點的手感很差，一顆 ↺ 解決。
    private func sliderRow(title: String, value: Binding<Double>,
                           range: ClosedRange<Double>, defaultValue: Double,
                           caption: @escaping () -> String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Slider(value: value, in: range) { Text(title) }
                Button {
                    value.wrappedValue = defaultValue
                } label: {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .disabled(abs(value.wrappedValue - defaultValue) < 0.001)
                .help("回預設")
            }
            Text(caption())
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
                // 邊界＝顯示 clamp（150…420），拖曳跟手。
                ColumnDividerHandle(width: $sidebarWidth, total: geo.size.width,
                                    sign: +1, minW: 150, maxW: 420)
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
        // 全域控制項色（含 List 系統選取膠囊）跟隨主題強調色——否則側邊欄
        // 有焦點時，系統藍膠囊會和我們的主題色底同框打架。
        .tint(Theme.accent)
        // Root tint must reach the very top of the window: SwiftUI keeps
        // per-view backgrounds inside the safe area, so without this the
        // titlebar strip is bare behind-window blur — a black-looking band
        // over a dark desktop (the "opaque titlebar" that survived every
        // titlebar-view sweep).
        .background(Theme.windowBG.ignoresSafeArea())
        .glassWindow(autosave: "JamesDesk.main")
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
            .tint(Theme.accent) // see ContentView
            .background(Theme.windowBG.ignoresSafeArea()) // see ContentView
            .glassWindow(autosave: "JamesDesk.task.\(slug)") // 每個任務各記各的位置
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
