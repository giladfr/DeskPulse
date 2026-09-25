import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var model: DashboardModel
    @EnvironmentObject private var settings: AppSettings
    @State private var canvasSize: CGSize = .zero
    @State private var savedSlotFeedback: Int?
    @State private var warSavedFeedback = false
    @State private var hoveredWidgetKind: WidgetKind?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The dashboard keeps refreshing while the HDMI screen is open in its own Space.
        dashboard
            .background(Color.black)
            .ignoresSafeArea()
            .background(FullScreenWindow())
            .onAppear {
                model.start()
                GlobalHotKey.shared.registerToggleHDMIScreen()
            }
            .onReceive(NotificationCenter.default.publisher(for: toggleHDMIScreenNotification)) { _ in
                toggleHDMIScreen()
            }
            // Clicking an alert or price notification shows the dashboard.
            .onReceive(NotificationCenter.default.publisher(for: notificationClickedNotification)) { _ in
                openWindow(id: DashboardWindow.id)
            }
            .onChange(of: model.warActivationRequest) { _, request in
                guard request > 0, model.activeLayout != .war else { return }
                withAnimation(.snappy(duration: 0.45)) {
                    model.activateWarLayout(in: canvasSize)
                }
            }
    }

    private var dashboard: some View {
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
                        .environmentObject(model.settings)
                        .zIndex(1)
                }
                Color.clear
                    .onAppear {
                        canvasSize = proxy.size
                        if model.activeLayout == .war && !model.hasSavedWarLayout {
                            model.activateWarLayout(in: proxy.size)
                        } else if model.needsInitialArrange {
                            model.autoArrange(in: proxy.size)
                        }
                    }
                    .onChange(of: proxy.size) { _, size in canvasSize = size }
            }
            .padding(.top, 68)
        }
        .ignoresSafeArea()
    }

    private var background: some View {
        let warMode = model.activeLayout == .war
        return ZStack {
            LinearGradient(
                colors: warMode
                    ? [
                        Color(red: 0.035, green: 0.025, blue: 0.035),
                        Color(red: 0.12, green: 0.025, blue: 0.035)
                    ]
                    : [
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
            if warMode {
                Circle()
                    .fill(Color.red.opacity(0.10))
                    .frame(width: 720)
                    .blur(radius: 110)
                    .offset(x: 420, y: -260)
            }
        }
    }

    /// Control–Command–H: from the HDMI screen go to the dashboard; from anywhere
    /// else (including other apps) open or switch to the HDMI screen.
    private func toggleHDMIScreen() {
        if NSApp.isActive, HDMIWindow.window?.isKeyWindow == true {
            openWindow(id: DashboardWindow.id)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            HDMIWindow.wasRequested = true
            openWindow(id: HDMIWindow.id)
        }
    }

    private var refreshHelp: String {
        if model.isRefreshing { return "Refreshing news and weather…" }
        let base = "Refresh news and weather now (they also refresh every 2 minutes)"
        guard let lastRefresh = model.lastRefresh else { return base }
        return "\(base) · last updated \(lastRefresh.formatted(date: .omitted, time: .shortened))"
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

                Button {
                    model.toggleIncomingAlertDetection()
                } label: {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                }
                .buttonStyle(HeaderButtonStyle(
                    active: model.incomingAlertDetectionEnabled,
                    activeColor: .red
                ))
                .help(
                    model.incomingAlertDetectionEnabled
                        ? "Red Alert detection is on — Home Front Command alerts notify you and activate the situation layout (areas in Settings → Alerts)"
                        : "Red Alert detection is off"
                )

                Button {
                    HDMIWindow.wasRequested = true
                    openWindow(id: HDMIWindow.id)
                } label: {
                    Image(systemName: "rectangle.on.rectangle.angled")
                }
                .buttonStyle(HeaderButtonStyle())
                .help("Open the HDMI input in its own full-screen Space — swipe between it and the dashboard (⌃⌘H from anywhere)")
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(WidgetKind.allCases.filter { !settings.hiddenFromTopBar.contains($0) }) { kind in
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
                    .onHover { hovering in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hoveredWidgetKind = hovering ? kind : nil
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if hoveredWidgetKind == kind {
                            Text(kind.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .fixedSize()
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Color.black.opacity(0.92))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                }
                                .offset(y: 34)
                                .allowsHitTesting(false)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
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
                warLayoutButton
            }
            Button {
                Task { await model.refresh() }
            } label: {
                // Dimmed rather than spun while refreshing: a repeat-forever rotation
                // also animated every layout shift, so the icon drifted out of its
                // pill and flickered.
                Image(systemName: "arrow.clockwise")
                    .opacity(model.isRefreshing ? 0.35 : 1)
                    .animation(.easeInOut(duration: 0.2), value: model.isRefreshing)
            }
            .buttonStyle(HeaderButtonStyle())
            .disabled(model.isRefreshing)
            .help(refreshHelp)
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
            SettingsLink {
                Image(systemName: "gearshape.fill")
            }
            .buttonStyle(HeaderButtonStyle())
            .help("Settings — weather city, stock watchlist, clocks and news sources (⌘,)")
        }
        .padding(.horizontal, 24)
        .frame(height: 68)
        .background(.ultraThinMaterial.opacity(0.82))
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func layoutSlotButton(_ slot: Int) -> some View {
        let isSaved = model.savedLayoutSlots.contains(slot)
        let justSaved = savedSlotFeedback == slot
        let isActive = model.activeLayout == .saved(slot)
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    justSaved
                        ? Color.green.opacity(0.28)
                        : isActive
                            ? Color.cyan.opacity(0.32)
                        : isSaved
                            ? Color.cyan.opacity(0.13)
                            : Color.white.opacity(0.035)
                )
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    justSaved
                        ? Color.green.opacity(0.65)
                        : isActive
                            ? Color.cyan.opacity(0.85)
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
            if isActive && !justSaved {
                Circle()
                    .fill(.green)
                    .frame(width: 5, height: 5)
                    .shadow(color: .green.opacity(0.8), radius: 3)
                    .offset(x: 9, y: -9)
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

    private var warLayoutButton: some View {
        let isActive = model.activeLayout == .war
        return ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(
                    warSavedFeedback
                        ? Color.green.opacity(0.28)
                        : isActive
                            ? Color.red.opacity(0.28)
                            : Color.white.opacity(0.035)
                )
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    warSavedFeedback
                        ? Color.green.opacity(0.65)
                        : isActive
                            ? Color.red.opacity(0.75)
                            : Color.white.opacity(0.08),
                    lineWidth: 1
                )
            Image(systemName: warSavedFeedback ? "checkmark" : "shield.lefthalf.filled")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(warSavedFeedback ? Color.green : Color.red)
                .shadow(
                    color: isActive && !warSavedFeedback
                        ? Color.red.opacity(0.75)
                        : .clear,
                    radius: 3
                )
        }
        .frame(width: 27, height: 27)
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .gesture(
            LongPressGesture(minimumDuration: 0.75)
                .exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first:
                        model.saveWarLayout()
                        warSavedFeedback = true
                        NSHapticFeedbackManager.defaultPerformer.perform(
                            .alignment,
                            performanceTime: .now
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            warSavedFeedback = false
                        }
                    case .second:
                        withAnimation(.snappy(duration: 0.4)) {
                            model.activateWarLayout(in: canvasSize)
                        }
                    }
                }
        )
        .help(
            model.hasSavedWarLayout
                ? "Israel situation layout: click to restore, press and hold to overwrite"
                : "Israel situation layout: click for the default, press and hold to save"
        )
        .accessibilityLabel("Israel situation layout")
        .accessibilityHint(
            model.hasSavedWarLayout
                ? "Click to restore or press and hold to overwrite"
                : "Click for the default layout or press and hold to save"
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
    var activeColor: Color = .cyan

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? .black : .white)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(
                active
                    ? activeColor
                    : Color.white.opacity(configuration.isPressed ? 0.16 : 0.08)
            )
            .clipShape(Capsule())
    }
}
