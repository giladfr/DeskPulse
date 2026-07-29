import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @State private var canvasSize: CGSize = .zero
    @State private var savedSlotFeedback: Int?

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            header
                .zIndex(100)

            GeometryReader { proxy in
                if model.snapsToGrid {
                    DashboardGrid(spacing: 16)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                        .zIndex(0)
                }
                ForEach(model.visibleWidgets) { widget in
                    WidgetFrame(widget: widget, canvasSize: proxy.size)
                        .environmentObject(model)
                        .zIndex(1)
                }
                Color.clear
                    .onAppear {
                        canvasSize = proxy.size
                        if model.needsInitialArrange {
                            model.autoArrange(in: proxy.size)
                        }
                    }
                    .onChange(of: proxy.size) { _, size in canvasSize = size }
            }
            .padding(.top, 68)
        }
        .ignoresSafeArea()
        .task { model.start() }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let window = NSApplication.shared.keyWindow,
                      !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.035, blue: 0.065),
                    Color(red: 0.055, green: 0.075, blue: 0.12)
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Circle()
                .fill(Color.blue.opacity(0.09))
                .frame(width: 620)
                .blur(radius: 90)
                .offset(x: -360, y: -300)
            Circle()
                .fill(Color.purple.opacity(0.07))
                .frame(width: 500)
                .blur(radius: 100)
                .offset(x: 540, y: 320)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.cyan)
            Text("DESK")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .tracking(2.5)
            Text("PULSE")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Button {
                    model.lockScreen()
                } label: {
                    Image(systemName: "lock.fill")
                }
                .buttonStyle(HeaderButtonStyle())
                .help("Lock this Mac")

                Button {
                    model.toggleSleepPrevention()
                } label: {
                    Image(systemName: model.preventsSleep ? "sun.max.fill" : "moon.zzz.fill")
                }
                .buttonStyle(HeaderButtonStyle(active: model.preventsSleep))
                .help(
                    model.preventsSleep
                        ? "Keep-awake is on — click to allow sleep"
                        : "Sleep is allowed — click to keep the display awake"
                )
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(WidgetKind.allCases) { kind in
                    Button {
                        model.toggleVisibility(kind)
                    } label: {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(model.isVisible(kind) ? kind.tint : .secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                model.isVisible(kind)
                                    ? kind.tint.opacity(0.14)
                                    : Color.white.opacity(0.035)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(
                                        model.isVisible(kind)
                                            ? kind.tint.opacity(0.28)
                                            : Color.white.opacity(0.06),
                                        lineWidth: 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .help("\(model.isVisible(kind) ? "Hide" : "Show") \(kind.title)")
                }
            }
            Divider()
                .frame(height: 22)
                .padding(.horizontal, 2)
            HStack(spacing: 5) {
                ForEach(1...4, id: \.self) { slot in
                    layoutSlotButton(slot)
                }
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(model.isRefreshing ? 360 : 0))
                    .animation(
                        model.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: model.isRefreshing
                    )
            }
            .buttonStyle(HeaderButtonStyle())
            Button {
                withAnimation(.snappy(duration: 0.35)) {
                    model.autoArrange(in: canvasSize)
                }
            } label: {
                Label("Auto arrange", systemImage: "rectangle.3.group")
            }
            .buttonStyle(HeaderButtonStyle())
            Button {
                model.toggleSnapToGrid()
            } label: {
                Image(systemName: model.snapsToGrid ? "grid.circle.fill" : "grid.circle")
            }
            .buttonStyle(HeaderButtonStyle(active: model.snapsToGrid))
            .help(
                model.snapsToGrid
                    ? "Snap to grid is on"
                    : "Snap to grid is off"
            )
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(.ultraThinMaterial.opacity(0.82))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func layoutSlotButton(_ slot: Int) -> some View {
        let isSaved = model.savedLayoutSlots.contains(slot)
        let justSaved = savedSlotFeedback == slot
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    justSaved
                        ? Color.green.opacity(0.28)
                        : isSaved
                            ? Color.cyan.opacity(0.13)
                            : Color.white.opacity(0.035)
                )
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    justSaved
                        ? Color.green.opacity(0.65)
                        : isSaved
                            ? Color.cyan.opacity(0.28)
                            : Color.white.opacity(0.08)
                )
            if justSaved {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                Text("\(slot)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(isSaved ? .white : .secondary)
            }
        }
        .frame(width: 27, height: 27)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .gesture(
            LongPressGesture(minimumDuration: 0.75)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first:
                        model.saveLayout(slot: slot)
                        savedSlotFeedback = slot
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .alignment,
                            performanceTime: .now
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            if savedSlotFeedback == slot {
                                savedSlotFeedback = nil
                            }
                        }
                    case .second:
                        withAnimation(.snappy(duration: 0.3)) {
                            _ = model.restoreLayout(slot: slot)
                        }
                    }
                }
        )
        .help(
            isSaved
                ? "Layout \(slot): click to restore, press and hold to overwrite"
                : "Layout \(slot): press and hold to save"
        )
        .accessibilityLabel("Saved layout \(slot)")
        .accessibilityHint(
            isSaved
                ? "Click to restore or press and hold to overwrite"
                : "Press and hold to save"
        )
    }
}

private struct DashboardGrid: View {
    let spacing: CGFloat

    var body: some View {
        Canvas { context, size in
            let dot = Path(
                ellipseIn: CGRect(x: -0.75, y: -0.75, width: 1.5, height: 1.5)
            )
            var x: CGFloat = spacing
            while x < size.width {
                var y: CGFloat = spacing
                while y < size.height {
                    context.fill(
                        dot.applying(CGAffineTransform(translationX: x, y: y)),
                        with: .color(.white.opacity(0.14))
                    )
                    y += spacing
                }
                x += spacing
            }
        }
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? .black : .white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(active ? Color.cyan : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            .clipShape(Capsule())
    }
}
