import AppKit
import SwiftUI
import TaskDeckCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Writing to the daemon socket after taskdeckd dies (crash, or a dev
        // restart) delivers SIGPIPE, which would kill the GUI outright. The
        // daemon already ignores it; the GUI must too — a dead socket should
        // surface as a write error, not a process death.
        signal(SIGPIPE, SIG_IGN)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `touch …/TaskDeck/snapshots/request` → PNGs of every window; see
        // SnapshotService. Dev aid, negligible cost, no permission prompts.
        MainActor.assumeIsolated { SnapshotService.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.model?.flushEverything()
        }
    }
}

private struct SidebarSearchCommands: Commands {
    @FocusedValue(\.focusSidebarSearch) private var focusSidebarSearch

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("搜尋任務標題") {
                focusSidebarSearch?()
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(focusSidebarSearch == nil)
        }
    }
}

/// View-size and appearance menu items. The ✓ marks read the keys AppModel
/// persists (its didSet writes them), not the model itself, so the main menu
/// is rebuilt only when the appearance changes — not on every model update.
private struct AppearanceCommands: Commands {
    let model: AppModel
    @AppStorage("accentHex") private var accentHex = 0x5B9DFF
    @AppStorage("bgPresetIndex") private var bgPresetIndex = 0

    var body: some Commands {
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
                        Button((UInt32(accentHex) == preset.hex ? "✓ " : "") + preset.name) {
                            model.accentHex = Int(preset.hex)
                        }
                    }
                }
                Menu("底色") {
                    ForEach(Array(Theme.bgPresets.enumerated()), id: \.offset) { i, preset in
                        Button((bgPresetIndex == i ? "✓ " : "") + preset.name) {
                            model.bgPresetIndex = i
                        }
                    }
                }
                Divider()
                SettingsLink { Text("外觀設定（透明度／明暗）…") }
            }
        }
    }
}

/// The one AppModel, deliberately outside SwiftUI's observation. As an
/// App-level @StateObject every @Published change re-evaluated the whole
/// Scene — each window's root view and the main menu — several times a second
/// while AI panes run. Views observe the model themselves (@EnvironmentObject).
@MainActor
private enum SharedModel {
    static let model = AppModel()
}

@main
struct TaskDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private var model: AppModel { SharedModel.model }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    AppDelegate.model = model
                    PerfTrace.startIfEnabled(model: model) // `defaults write … perfTrace -bool true`
                }
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
            AppearanceCommands(model: model)
            SidebarSearchCommands()
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
                .priorityAlertChrome()
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
        .priorityAlertChrome()
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
            .priorityAlertChrome()
            .glassWindow(autosave: "JamesDesk.task.\(slug)") // 每個任務各記各的位置
            .preferredColorScheme(.dark)
    }
}

/// The empty state's blinking cursor block, blinked by Core Animation like
/// `PulseRing`. A SwiftUI `repeatForever` keeps the window's display list
/// re-rendering every frame for as long as it runs, and this one was started
/// from `onAppear` at launch — the empty state shows for a moment before the
/// first task is selected — inside the same update as the first layout.
private struct CursorBlock: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> CursorBlockView { CursorBlockView() }

    func updateNSView(_ view: CursorBlockView, context: Context) {
        view.apply(color: NSColor(Theme.accent), blinking: !reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CursorBlockView,
                      context: Context) -> CGSize? {
        CursorBlockView.size
    }
}

/// 22 × 34 pt accent block with a soft glow, fading 1 → 0.15 and back every
/// 0.6 s while `blinking`; solid otherwise (Reduce Motion).
private final class CursorBlockView: NSView {
    static let size = CGSize(width: 22, height: 34)
    private static let animationKey = "blink"

    private let block = CALayer()
    private var blinking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        block.bounds = CGRect(origin: .zero, size: Self.size)
        block.cornerRadius = 5
        block.cornerCurve = .continuous
        block.shadowOpacity = 0.55
        block.shadowRadius = 18
        block.shadowOffset = .zero
        block.shadowPath = CGPath(roundedRect: block.bounds, cornerWidth: 5, cornerHeight: 5,
                                  transform: nil)
        // No implicit 0.25 s fades when the colour or position is set.
        block.actions = ["backgroundColor": NSNull(), "shadowColor": NSNull(),
                         "position": NSNull()]
        layer?.addSublayer(block)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { Self.size }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        block.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if block.superlayer == nil { layer?.addSublayer(block) }
        block.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func apply(color: NSColor, blinking: Bool) {
        block.backgroundColor = color.cgColor
        block.shadowColor = color.cgColor
        guard blinking != self.blinking else { return }
        self.blinking = blinking
        if blinking {
            let blink = CABasicAnimation(keyPath: "opacity")
            blink.fromValue = 1.0
            blink.toValue = 0.15
            blink.duration = 0.6
            blink.autoreverses = true
            blink.repeatCount = .infinity
            blink.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            block.add(blink, forKey: Self.animationKey)
        } else {
            block.removeAnimation(forKey: Self.animationKey)
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // A blinking cursor block instead of a grey grid glyph: this is a
        // terminal workbench, and the cursor is its identity.
        VStack(spacing: 12) {
            CursorBlock()
                .padding(.bottom, 6)
            Text("選一個任務")
                .font(Theme.Fonts.display(22, .bold))
                .foregroundStyle(Theme.text)
            Text("或開一個新的")
                .font(Theme.Fonts.ui(13))
                .foregroundStyle(Theme.text3)
            Button { model.newTask() } label: {
                Text("新任務  ⇧⌘N")
                    .font(Theme.Fonts.ui(12.5, .semibold))
                    .foregroundStyle(Color(hex: 0x0A0C11))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBG)
    }
}
