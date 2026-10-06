import AppKit
import ScreenCaptureKit

enum SelectionResult {
    case area(FrozenScreen, CGRect)
    case window(WindowTarget)
    case cancelled
}

/// Takes keyboard focus without activating SnapStash, so the app you were in stays frontmost.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Covers every screen with its frozen image and lets you drag out an area or pick a window.
@MainActor
final class SelectionOverlay {
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    private var keyMonitor: Any?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var idleTimer: Timer?
    private var completion: ((SelectionResult) -> Void)?
    private(set) var windowMode: Bool

    init(windowMode: Bool) {
        self.windowMode = windowMode
    }

    func begin(frozen: [FrozenScreen], windows: [WindowTarget], completion: @escaping (SelectionResult) -> Void) {
        self.completion = completion
        for screen in frozen {
            let panel = OverlayPanel(contentRect: screen.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.hasShadow = false
            panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            // The frozen image goes in its own layer-backed view underneath; the overlay view on top
            // only draws the dimming, selection and magnifier.
            let container = NSView(frame: NSRect(origin: .zero, size: screen.screen.frame.size))
            let backdrop = NSView(frame: container.bounds)
            backdrop.wantsLayer = true
            backdrop.layer?.contents = screen.image
            backdrop.layer?.contentsGravity = .resize
            backdrop.layer?.magnificationFilter = .nearest
            backdrop.autoresizingMask = [.width, .height]
            let view = OverlayView(frozen: screen, windows: windows, overlay: self)
            view.frame = container.bounds
            view.autoresizingMask = [.width, .height]
            container.addSubview(backdrop)
            container.addSubview(view)
            panel.contentView = container
            panel.setFrame(screen.screen.frame, display: false)
            panels.append(panel)
            views.append(view)
        }
        for panel in panels { panel.orderFrontRegardless() }
        // Focus the panel under the mouse so Esc and Space reach us.
        let mouse = NSEvent.mouseLocation
        (panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first)?.makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            self.noteActivity()
            switch Int(event.keyCode) {
            case 53: self.finish(.cancelled); return nil                 // esc
            case 49: self.toggleWindowMode(); return nil                 // space
            default: return event
            }
        }
        for view in views { view.refreshHover() }

        // The overlay covers every screen, so it must never outlive the situation it was made for:
        // the frozen images no longer match after a display change, and nobody is there after sleep
        // or a user switch.
        let app = NotificationCenter.default, workspace = NSWorkspace.shared.notificationCenter
        let cancelOn: [(NotificationCenter, Notification.Name, String?)] = [
            (app, NSApplication.didChangeScreenParametersNotification, "Capture cancelled because the displays changed"),
            (workspace, NSWorkspace.willSleepNotification, nil),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, nil),
        ]
        for (center, name, message) in cancelOn {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.completion != nil else { return }
                    self.finish(.cancelled)
                    if let message { Toast.show(message, symbol: "exclamationmark.triangle.fill") }
                }
            }
            observers.append((center, token))
        }
        noteActivity()
    }

    /// Restarts the idle timer. If nothing happens for two minutes (e.g. focus was lost so Esc can't
    /// reach us), the overlay closes itself rather than leaving the screens covered.
    func noteActivity() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(.cancelled) }
        }
    }

    func toggleWindowMode() {
        windowMode.toggle()
        for view in views { view.refreshHover() }
    }

    func finish(_ result: SelectionResult) {
        guard let completion else { return }
        self.completion = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        completion(result)
    }
}

/// One screen's overlay: draws the dimming, selection and magnifier over the frozen image beneath it.
final class OverlayView: NSView {
    private let frozen: FrozenScreen
    private let windows: [WindowTarget]
    private weak var overlay: SelectionOverlay?

    private var dragStart: NSPoint?
    private var selection: NSRect?
    private var mouse: NSPoint?
    private var hoveredWindow: WindowTarget?

    init(frozen: FrozenScreen, windows: [WindowTarget], overlay: SelectionOverlay) {
        self.frozen = frozen
        self.windows = windows
        self.overlay = overlay
        super.init(frame: NSRect(origin: .zero, size: frozen.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    private var windowMode: Bool { overlay?.windowMode ?? false }

    /// Local point -> global AppKit point.
    private func global(_ point: NSPoint) -> NSPoint {
        NSPoint(x: point.x + frozen.screen.frame.minX, y: point.y + frozen.screen.frame.minY)
    }

    /// Global AppKit rect -> local rect.
    private func local(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: -frozen.screen.frame.minX, dy: -frozen.screen.frame.minY)
    }

    func refreshHover() {
        let point = window.map { $0.mouseLocationOutsideOfEventStream } ?? mouse
        mouse = point
        updateHover()
        needsDisplay = true
    }

    private func updateHover() {
        guard let mouse, selection == nil else { hoveredWindow = nil; return }
        let globalPoint = global(mouse)
        hoveredWindow = windows.first { $0.frame.contains(globalPoint) }
    }

    // MARK: Mouse

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        overlay?.noteActivity()
        mouse = convert(event.locationInWindow, from: nil)
        updateHover()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        mouse = point
        if !windowMode { selection = NSRect(origin: point, size: .zero) }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !windowMode, let start = dragStart else { return }
        var point = convert(event.locationInWindow, from: nil)
        point.x = min(max(point.x, 0), bounds.width)
        point.y = min(max(point.y, 0), bounds.height)
        mouse = point
        var rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        if event.modifierFlags.contains(.shift) { // square
            let side = max(rect.width, rect.height)
            rect.size = NSSize(width: side, height: side)
            if point.x < start.x { rect.origin.x = start.x - side }
            if point.y < start.y { rect.origin.y = start.y - side }
        }
        selection = rect.integral
        hoveredWindow = nil
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if let selection, selection.width >= 4, selection.height >= 4, !windowMode {
            overlay?.finish(.area(frozen, selection))
            return
        }
        // A click without a drag (or any click in window mode) picks the window under the pointer.
        selection = nil
        updateHover()
        if let hoveredWindow {
            overlay?.finish(.window(hoveredWindow))
        } else {
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) { overlay?.finish(.cancelled) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        let accent = NSColor.controlAccentColor

        if let hoveredWindow {
            let frame = local(hoveredWindow.frame)
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: frame))
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            accent.withAlphaComponent(0.18).setFill()
            frame.fill()
            accent.setStroke()
            let border = NSBezierPath(rect: frame.insetBy(dx: 1, dy: 1))
            border.lineWidth = 2
            border.stroke()
            drawLabel("\(hoveredWindow.appName)  \(Int(hoveredWindow.frame.width)) × \(Int(hoveredWindow.frame.height))",
                      near: NSPoint(x: frame.midX, y: frame.midY), centered: true)
        } else if let selection {
            let path = NSBezierPath(rect: bounds)
            path.append(NSBezierPath(rect: selection))
            path.windingRule = .evenOdd
            dim.setFill()
            path.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            let pixels = "\(Int(selection.width * frozen.scale)) × \(Int(selection.height * frozen.scale))"
            drawLabel(pixels, near: NSPoint(x: selection.maxX, y: selection.minY), centered: false)
        } else {
            dim.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }

        if !windowMode, let mouse, NSMouseInRect(mouse, bounds, false) {
            drawCrosshair(at: mouse)
            drawMagnifier(at: mouse)
        }
        if windowMode && hoveredWindow == nil, let mouse, NSMouseInRect(mouse, bounds, false) {
            drawLabel("Click a window  ·  Space for area  ·  Esc to cancel", near: mouse, centered: false)
        }
    }

    private func drawCrosshair(at point: NSPoint) {
        guard selection == nil else { return }
        NSColor.white.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: point.x, y: 0)); path.line(to: NSPoint(x: point.x, y: bounds.height))
        path.move(to: NSPoint(x: 0, y: point.y)); path.line(to: NSPoint(x: bounds.width, y: point.y))
        path.lineWidth = 0.5
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
    }

    /// A zoomed view of the pixels around the pointer, for pixel-exact edges.
    private func drawMagnifier(at point: NSPoint) {
        let sourcePixels: CGFloat = 15
        let size: CGFloat = 120
        let scale = frozen.scale
        let center = CGPoint(x: point.x * scale, y: (bounds.height - point.y) * scale)
        let source = CGRect(x: floor(center.x - sourcePixels / 2), y: floor(center.y - sourcePixels / 2),
                            width: sourcePixels, height: sourcePixels)
        guard let crop = frozen.image.cropping(to: source), let context = NSGraphicsContext.current?.cgContext else { return }

        var origin = NSPoint(x: point.x + 24, y: point.y - size - 24)
        if origin.x + size > bounds.width { origin.x = point.x - size - 24 }
        if origin.y < 0 { origin.y = point.y + 24 }
        let frame = NSRect(origin: origin, size: NSSize(width: size, height: size))

        context.saveGState()
        let clip = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        clip.addClip()
        context.interpolationQuality = .none
        context.draw(crop, in: frame)
        // Center pixel outline.
        let cell = size / sourcePixels
        NSColor.controlAccentColor.setStroke()
        NSBezierPath(rect: NSRect(x: frame.midX - cell / 2, y: frame.midY - cell / 2, width: cell, height: cell)).stroke()
        context.restoreGState()
        NSColor.white.setStroke()
        let ring = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        ring.lineWidth = 2
        ring.stroke()

        let coords = "\(Int(point.x * scale)), \(Int((bounds.height - point.y) * scale))"
        drawLabel(coords, near: NSPoint(x: frame.midX, y: frame.minY - 4), centered: true, below: true)
    }

    private func drawLabel(_ text: String, near point: NSPoint, centered: Bool, below: Bool = false) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        var box = NSRect(x: 0, y: 0, width: size.width + 12, height: size.height + 6)
        if centered {
            box.origin = NSPoint(x: point.x - box.width / 2, y: below ? point.y - box.height : point.y - box.height / 2)
        } else {
            box.origin = NSPoint(x: point.x + 8, y: point.y - box.height - 8)
        }
        box.origin.x = min(max(box.origin.x, 4), bounds.width - box.width - 4)
        box.origin.y = min(max(box.origin.y, 4), bounds.height - box.height - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        string.draw(at: NSPoint(x: box.minX + 6, y: box.minY + 3))
    }
}
