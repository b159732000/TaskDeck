import AppKit
import SwiftUI
import TaskDeckCore

/// App-wide chrome for unacknowledged main-line task completions.
///
/// The vignette is deliberately transient: it catches attention without
/// blocking the task the user is currently finishing. The rim and banner
/// remain until every pending task has been acknowledged by AppModel.
private struct PriorityAlertChromeModifier: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var vignetteOpacity = 0.0
    @State private var pulseTask: Task<Void, Never>?

    private var hasAlerts: Bool { !model.priorityAlertTasks.isEmpty }

    func body(content: Content) -> some View {
        content
            .overlay {
                if hasAlerts {
                    PriorityAlertRim()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if hasAlerts, vignetteOpacity > 0 {
                    PriorityAlertVignette()
                        .opacity(vignetteOpacity)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .top) {
                if hasAlerts {
                    PriorityAlertBanner()
                        .padding(.top, 10)
                        .padding(.horizontal, 16)
                }
            }
            .onChange(of: model.priorityAlertPulse) { _, _ in
                guard hasAlerts else { return }
                playVignette()
            }
            .onChange(of: hasAlerts) { _, pending in
                guard !pending else { return }
                pulseTask?.cancel()
                pulseTask = nil
                vignetteOpacity = 0
            }
            .onDisappear {
                pulseTask?.cancel()
                pulseTask = nil
            }
    }

    private func playVignette() {
        pulseTask?.cancel()
        pulseTask = Task { @MainActor in
            vignetteOpacity = 0

            if reduceMotion {
                vignetteOpacity = 0.72
                do {
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                } catch {
                    return
                }
                vignetteOpacity = 0
                return
            }

            // Two short pulses total roughly 1.5 seconds.
            for _ in 0..<2 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    vignetteOpacity = 1
                }
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
                withAnimation(.easeIn(duration: 0.34)) {
                    vignetteOpacity = 0
                }
                do {
                    try await Task.sleep(nanoseconds: 450_000_000)
                } catch {
                    return
                }
            }
        }
    }
}

private struct PriorityAlertRim: View {
    private let gradient = AngularGradient(
        colors: [
            Color(red: 1.00, green: 0.19, blue: 0.25),
            Color(red: 1.00, green: 0.42, blue: 0.30),
            Color(red: 0.95, green: 0.12, blue: 0.35),
            Color(red: 1.00, green: 0.19, blue: 0.25),
        ],
        center: .center
    )

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(gradient, lineWidth: 4)
            .shadow(color: Color.red.opacity(0.48), radius: 9)
            .padding(1)
            .ignoresSafeArea()
    }
}

private struct PriorityAlertVignette: View {
    private let hot = Color(red: 1.00, green: 0.08, blue: 0.18)
    private let warm = Color(red: 1.00, green: 0.38, blue: 0.22)

    var body: some View {
        GeometryReader { proxy in
            let verticalDepth = min(max(proxy.size.height * 0.14, 62), 104)
            let horizontalDepth = min(max(proxy.size.width * 0.08, 62), 112)

            ZStack {
                VStack(spacing: 0) {
                    edgeGradient(start: .top, end: .bottom)
                        .frame(height: verticalDepth)
                    Spacer(minLength: 0)
                    edgeGradient(start: .bottom, end: .top)
                        .frame(height: verticalDepth)
                }

                HStack(spacing: 0) {
                    edgeGradient(start: .leading, end: .trailing)
                        .frame(width: horizontalDepth)
                    Spacer(minLength: 0)
                    edgeGradient(start: .trailing, end: .leading)
                        .frame(width: horizontalDepth)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
    }

    private func edgeGradient(start: UnitPoint, end: UnitPoint) -> some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: hot.opacity(0.72), location: 0),
                        .init(color: warm.opacity(0.30), location: 0.42),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: start,
                    endPoint: end
                )
            )
    }
}

private struct PriorityAlertBanner: View {
    @EnvironmentObject private var model: AppModel

    private var tasks: [TaskNote] { model.priorityAlertTasks }
    private var firstTask: TaskNote? { tasks.first }

    private var summary: String {
        guard tasks.count == 1, let task = firstTask else {
            return "\(tasks.count) 個主線任務等你"
        }
        return "主線已就緒 · \(task.title)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .foregroundStyle(PriorityAlertPalette.gradient)

            Text(summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Button("回到主線") {
                guard let firstTask else { return }
                model.focusPriorityTask(firstTask.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(PriorityAlertPalette.coral)
            .disabled(firstTask == nil)

            if tasks.count > 1 {
                Menu {
                    ForEach(tasks) { task in
                        Button(task.title) {
                            model.focusPriorityTask(task.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("選擇主線任務")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(PriorityAlertPalette.gradient, lineWidth: 1.5)
        }
        .shadow(color: PriorityAlertPalette.red.opacity(0.42), radius: 13, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(summary)
    }
}

private enum PriorityAlertPalette {
    static let red = Color(red: 1.00, green: 0.16, blue: 0.25)
    static let coral = Color(red: 0.94, green: 0.27, blue: 0.22)
    static let gradient = LinearGradient(
        colors: [red, Color(red: 1.00, green: 0.46, blue: 0.30)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// Mouse-down observer scoped to the actual task-detail rectangle. A SwiftUI
/// gesture is insufficient here because SwiftTerm and the notes editor are
/// embedded AppKit views that consume their own events. The local monitor sees
/// those clicks, while the bounds check keeps sidebar clicks from dismissing
/// the previously selected task's reminder.
private struct PriorityAlertTaskInteractionProbe: NSViewRepresentable {
    @EnvironmentObject private var model: AppModel
    let slug: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PassthroughView {
        let view = PassthroughView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PassthroughView, context: Context) {
        context.coordinator.model = model
        context.coordinator.slug = slug
    }

    static func dismantleNSView(_ nsView: PassthroughView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor
    final class Coordinator {
        weak var model: AppModel?
        var slug = ""
        private weak var probe: PassthroughView?
        private var monitor: Any?

        func attach(to probe: PassthroughView) {
            self.probe = probe
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
            ) { [weak self] event in
                guard let self,
                      let probe = self.probe,
                      event.window === probe.window else { return event }
                let point = probe.convert(event.locationInWindow, from: nil)
                guard probe.visibleRect.contains(point),
                      let model = self.model,
                      model.hasPriorityAlert(self.slug) else { return event }

                let clickedSlug = self.slug
                DispatchQueue.main.async { [weak model] in
                    model?.dismissPriorityAlert(clickedSlug)
                }
                return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            probe = nil
            model = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension View {
    func priorityAlertChrome() -> some View {
        modifier(PriorityAlertChromeModifier())
    }

    func dismissPriorityAlertOnTaskInteraction(_ slug: String) -> some View {
        background(PriorityAlertTaskInteractionProbe(slug: slug))
    }
}
