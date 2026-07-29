import SwiftUI
import AppKit

struct WidgetFrame: View {
    @EnvironmentObject private var model: DashboardModel
    let widget: DashboardWidget
    let canvasSize: CGSize
    @State private var dragOrigin: CGPoint?
    @State private var resizeOrigin: CGRect?
    @State private var previewPosition: CGPoint?
    @State private var previewSize: CGSize?
    @State private var isHovering = false

    private var displayedX: Double {
        Double(previewPosition?.x ?? CGFloat(widget.x))
    }
    private var displayedY: Double {
        Double(previewPosition?.y ?? CGFloat(widget.y))
    }
    private var displayedWidth: Double {
        Double(previewSize?.width ?? CGFloat(widget.width))
    }
    private var displayedHeight: Double {
        Double(previewSize?.height ?? CGFloat(widget.height))
    }

    var body: some View {
        WidgetCard(kind: widget.kind) {
            WidgetContent(kind: widget.kind)
        }
        .frame(width: displayedWidth, height: displayedHeight)
        .overlay(alignment: .topTrailing) {
            Button {
                model.remove(widget.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.72))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(5)
        }
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.white.opacity(0.018))
                    .overlay {
                        Capsule()
                            .fill(Color.white.opacity(isHovering ? 0.34 : 0.16))
                            .frame(width: 30, height: 3)
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(moveGesture)
                Color.clear.frame(width: 34)
            }
            .frame(height: 32)
        }
        .overlay {
            WidgetResizeOverlay(
                onChanged: updateResize,
                onEnded: finishResize
            )
        }
        .overlay {
            WidgetHoverTracker { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovering = hovering
                }
            }
        }
        .position(
            x: clampedX(displayedX + displayedWidth / 2, width: displayedWidth),
            y: clampedY(displayedY + displayedHeight / 2, height: displayedHeight)
        )
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: widget.x, y: widget.y)
                }
                guard let origin = dragOrigin else { return }
                previewPosition = CGPoint(
                    x: aligned(max(8, min(
                        origin.x + value.translation.width,
                        canvasSize.width - displayedWidth - 8
                    ))),
                    y: aligned(max(8, min(
                        origin.y + value.translation.height,
                        canvasSize.height - displayedHeight - 8
                    )))
                )
            }
            .onEnded { value in
                guard let origin = dragOrigin else { return }
                var changed = widget
                changed.x = aligned(max(8, min(
                    origin.x + value.translation.width,
                    canvasSize.width - displayedWidth - 8
                )))
                changed.y = aligned(max(8, min(
                    origin.y + value.translation.height,
                    canvasSize.height - displayedHeight - 8
                )))
                model.update(changed)
                dragOrigin = nil
                DispatchQueue.main.async { previewPosition = nil }
            }
    }

    private func updateResize(_ direction: ResizeDirection, _ translation: CGSize) {
        if resizeOrigin == nil {
            resizeOrigin = CGRect(
                x: widget.x, y: widget.y,
                width: widget.width, height: widget.height
            )
        }
        guard let origin = resizeOrigin else { return }
        let frame = resizedFrame(
            from: origin,
            translation: translation,
            direction: direction
        )
        previewPosition = frame.origin
        previewSize = frame.size
    }

    private func finishResize(_ direction: ResizeDirection, _ translation: CGSize) {
        guard let origin = resizeOrigin else { return }
        let frame = resizedFrame(
            from: origin,
            translation: translation,
            direction: direction
        )
        var changed = widget
        changed.x = frame.minX
        changed.y = frame.minY
        changed.width = frame.width
        changed.height = frame.height
        model.update(changed)
        resizeOrigin = nil
        DispatchQueue.main.async {
            previewPosition = nil
            previewSize = nil
        }
    }

    private func resizedFrame(
        from origin: CGRect,
        translation: CGSize,
        direction: ResizeDirection
    ) -> CGRect {
        let minimumWidth = 220.0
        let minimumHeight = 150.0
        let margin = 8.0
        var left = origin.minX
        var right = origin.maxX
        var top = origin.minY
        var bottom = origin.maxY

        if direction.movesLeft {
            left = aligned(max(margin, min(
                origin.minX + translation.width,
                origin.maxX - minimumWidth
            )))
        }
        if direction.movesRight {
            right = aligned(min(canvasSize.width - margin, max(
                origin.maxX + translation.width,
                origin.minX + minimumWidth
            )))
        }
        if direction.movesTop {
            top = aligned(max(margin, min(
                origin.minY + translation.height,
                origin.maxY - minimumHeight
            )))
        }
        if direction.movesBottom {
            bottom = aligned(min(canvasSize.height - margin, max(
                origin.maxY + translation.height,
                origin.minY + minimumHeight
            )))
        }

        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func aligned(_ value: Double) -> Double {
        guard model.snapsToGrid else { return value }
        return (value / 16).rounded() * 16
    }
    private func aligned(_ value: CGFloat) -> CGFloat {
        CGFloat(aligned(Double(value)))
    }
    private func clampedX(_ value: Double, width: Double) -> Double {
        min(max(value, width / 2), canvasSize.width - width / 2)
    }

    private func clampedY(_ value: Double, height: Double) -> Double {
        min(max(value, height / 2), canvasSize.height - height / 2)
    }
}

private enum ResizeDirection: CaseIterable, Equatable {
    case top, left, bottom, right
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .top: .top
            case .left: .left
            case .bottom: .bottom
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }
        return (movesLeft || movesRight) ? .resizeLeftRight : .resizeUpDown
    }
}

private struct WidgetResizeOverlay: NSViewRepresentable {
    let onChanged: (ResizeDirection, CGSize) -> Void
    let onEnded: (ResizeDirection, CGSize) -> Void

    func makeNSView(context: Context) -> BorderResizeView {
        let view = BorderResizeView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ view: BorderResizeView, context: Context) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.window?.invalidateCursorRects(for: view)
    }

    final class BorderResizeView: NSView {
        var onChanged: ((ResizeDirection, CGSize) -> Void)?
        var onEnded: ((ResizeDirection, CGSize) -> Void)?
        private var activeDirection: ResizeDirection?
        private var dragStart = NSPoint.zero
        private let edgeWidth: CGFloat = 6
        private let cornerSize: CGFloat = 12

        override func hitTest(_ point: NSPoint) -> NSView? {
            direction(at: point) == nil ? nil : self
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            for direction in ResizeDirection.allCases {
                addCursorRect(rect(for: direction), cursor: direction.cursor)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let localPoint = convert(event.locationInWindow, from: nil)
            activeDirection = direction(at: localPoint)
            dragStart = event.locationInWindow
        }

        override func mouseDragged(with event: NSEvent) {
            guard let activeDirection else { return }
            onChanged?(activeDirection, translation(for: event))
        }

        override func mouseUp(with event: NSEvent) {
            guard let activeDirection else { return }
            onEnded?(activeDirection, translation(for: event))
            self.activeDirection = nil
            window?.invalidateCursorRects(for: self)
        }

        private func translation(for event: NSEvent) -> CGSize {
            CGSize(
                width: event.locationInWindow.x - dragStart.x,
                height: dragStart.y - event.locationInWindow.y
            )
        }

        private func direction(at point: NSPoint) -> ResizeDirection? {
            guard bounds.contains(point) else { return nil }
            let nearLeft = point.x <= cornerSize
            let nearRight = point.x >= bounds.width - cornerSize
            let nearBottom = point.y <= cornerSize
            let nearTop = point.y >= bounds.height - cornerSize
            if nearTop && nearLeft { return .topLeft }
            if nearTop && nearRight { return .topRight }
            if nearBottom && nearLeft { return .bottomLeft }
            if nearBottom && nearRight { return .bottomRight }
            if point.y >= bounds.height - edgeWidth { return .top }
            if point.y <= edgeWidth { return .bottom }
            if point.x <= edgeWidth { return .left }
            if point.x >= bounds.width - edgeWidth { return .right }
            return nil
        }

        private func rect(for direction: ResizeDirection) -> NSRect {
            switch direction {
            case .top:
                NSRect(
                    x: cornerSize, y: bounds.height - edgeWidth,
                    width: max(0, bounds.width - cornerSize * 2), height: edgeWidth
                )
            case .bottom:
                NSRect(
                    x: cornerSize, y: 0,
                    width: max(0, bounds.width - cornerSize * 2), height: edgeWidth
                )
            case .left:
                NSRect(
                    x: 0, y: cornerSize,
                    width: edgeWidth, height: max(0, bounds.height - cornerSize * 2)
                )
            case .right:
                NSRect(
                    x: bounds.width - edgeWidth, y: cornerSize,
                    width: edgeWidth, height: max(0, bounds.height - cornerSize * 2)
                )
            case .topLeft:
                NSRect(x: 0, y: bounds.height - cornerSize, width: cornerSize, height: cornerSize)
            case .topRight:
                NSRect(
                    x: bounds.width - cornerSize, y: bounds.height - cornerSize,
                    width: cornerSize, height: cornerSize
                )
            case .bottomLeft:
                NSRect(x: 0, y: 0, width: cornerSize, height: cornerSize)
            case .bottomRight:
                NSRect(
                    x: bounds.width - cornerSize, y: 0,
                    width: cornerSize, height: cornerSize
                )
            }
        }
    }
}

private struct WidgetHoverTracker: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onHover = onHover
    }

    final class TrackingView: NSView {
        var onHover: ((Bool) -> Void)?
        private var trackingAreaReference: NSTrackingArea?

        override func updateTrackingAreas() {
            if let trackingAreaReference {
                removeTrackingArea(trackingAreaReference)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingAreaReference = area
            super.updateTrackingAreas()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }
    }
}

struct WidgetCard<Content: View>: View {
    let kind: WidgetKind
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(kind.tint)
                    .frame(width: 20, height: 20)
                    .background(kind.tint.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(kind.title.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 11)
            .frame(height: 32)
            Divider().opacity(0.22)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.ultraThinMaterial)
        .background(Color(red: 0.07, green: 0.085, blue: 0.13).opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 20, y: 9)
    }
}
