import AppKit
import SwiftUI

/// The thumbnails stacked in the bottom-left corner after each capture.
@MainActor
final class QuickAccess {
    static let shared = QuickAccess()

    private struct Entry {
        let capture: Capture
        let panel: NSPanel
        var dismissWork: DispatchWorkItem?
    }

    private var entries: [Entry] = []
    private let width: CGFloat = 240
    private let margin: CGFloat = 20
    private let spacing: CGFloat = 12

    func show(_ capture: Capture) {
        let aspect = CGFloat(capture.image.height) / CGFloat(max(capture.image.width, 1))
        let height = min(max(width * aspect, 90), 260)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: QuickAccessCard(
            capture: capture,
            onHover: { [weak self] hovering in self?.setPaused(capture.id, hovering) },
            onClose: { [weak self] in self?.dismiss(capture.id) }))
        entries.insert(Entry(capture: capture, panel: panel), at: 0)
        layout(animated: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        scheduleDismiss(capture.id)
        layout(animated: true)
        // Keep the stack manageable.
        if entries.count > 5, let oldest = entries.last { dismiss(oldest.capture.id) }
    }

    func dismiss(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.capture.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.dismissWork?.cancel()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; entry.panel.animator().alphaValue = 0 },
                                             completionHandler: {
            // Ordering out alone leaves AppKit holding the panel, and with it the full-size capture.
            entry.panel.orderOut(nil)
            entry.panel.contentView = nil
            entry.panel.close()
        })
        layout(animated: true)
    }

    private func setPaused(_ id: UUID, _ paused: Bool) {
        guard let index = entries.firstIndex(where: { $0.capture.id == id }) else { return }
        if paused {
            entries[index].dismissWork?.cancel()
            entries[index].dismissWork = nil
        } else {
            scheduleDismiss(id)
        }
    }

    private func scheduleDismiss(_ id: UUID) {
        let seconds = Prefs.quickAccessSeconds
        guard seconds > 0, let index = entries.firstIndex(where: { $0.capture.id == id }) else { return }
        entries[index].dismissWork?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { QuickAccess.shared.dismiss(id) } }
        entries[index].dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    /// Newest at the bottom, older ones stacked above it.
    private func layout(animated: Bool) {
        guard let screen = NSScreen.underMouse else { return }
        var y = screen.visibleFrame.minY + margin
        for entry in entries {
            let frame = NSRect(x: screen.visibleFrame.minX + margin, y: y,
                               width: entry.panel.frame.width, height: entry.panel.frame.height)
            if animated {
                NSAnimationContext.runAnimationGroup { $0.duration = 0.18; entry.panel.animator().setFrame(frame, display: true) }
            } else {
                entry.panel.setFrame(frame, display: true)
            }
            y += frame.height + spacing
        }
    }
}

private struct QuickAccessCard: View {
    let capture: Capture
    let onHover: (Bool) -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Image(nsImage: capture.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            if hovering {
                Color.black.opacity(0.45)
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        CardButton(title: "Copy", symbol: "doc.on.doc") {
                            if capture.copyToClipboard() {
                                Toast.show("Copied to clipboard")
                                onClose()
                            }
                        }
                        CardButton(title: "Save", symbol: "square.and.arrow.down") {
                            if capture.saveReporting() { onClose() }
                        }
                    }
                    HStack(spacing: 8) {
                        CardButton(title: "Pin", symbol: "pin") {
                            PinWindow.show(capture)
                            onClose()
                        }
                        CardButton(title: "Text", symbol: "text.viewfinder") {
                            Task {
                                await CaptureCoordinator.shared.copyText(from: capture.image)
                                onClose()
                            }
                        }
                    }
                }
                .padding(10)
            }
        }
        .overlay(alignment: .topLeading) {
            if hovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Close")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), lineWidth: 1))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
            onHover(inside)
        }
        .onDrag {
            // Dropping the thumbnail into another app hands it the image file.
            guard let url = capture.fileForDragging() else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Copy") { if capture.copyToClipboard() { onClose() } }
            Button("Save") { if capture.saveReporting() { onClose() } }
            Button("Save As…") { capture.saveAs(); onClose() }
            Button("Pin to Screen") { PinWindow.show(capture); onClose() }
            Button("Copy Text") { Task { await CaptureCoordinator.shared.copyText(from: capture.image); onClose() } }
            Divider()
            Button("Close") { onClose() }
        }
    }
}

private struct CardButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(0.92)))
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
    }
}

/// A screenshot floating above every window: drag to move, scroll or pinch to zoom,
/// double-click or Esc to close.
@MainActor
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []
    private let capture: Capture

    static func show(_ capture: Capture) {
        let window = PinWindow(capture: capture)
        open.append(window)
        window.orderFrontRegardless()
        window.makeKey()
    }

    private init(capture: Capture) {
        self.capture = capture
        var size = capture.pointSize
        if let visible = NSScreen.underMouse?.visibleFrame {
            let fit = min(1, visible.width * 0.6 / size.width, visible.height * 0.6 / size.height)
            size = NSSize(width: size.width * fit, height: size.height * fit)
        }
        let origin = NSScreen.underMouse.map { NSPoint(x: $0.visibleFrame.midX - size.width / 2, y: $0.visibleFrame.midY - size.height / 2) } ?? .zero
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        contentAspectRatio = capture.pointSize
        minSize = NSSize(width: 60, height: 60)

        let imageView = PinImageView(frame: NSRect(origin: .zero, size: size))
        imageView.image = capture.nsImage
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        imageView.autoresizingMask = [.width, .height]
        imageView.pin = self
        contentView = imageView
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { closePin() } else { super.keyDown(with: event) }
    }

    func zoom(by factor: CGFloat) {
        var frame = self.frame
        let newWidth = min(max(frame.width * factor, 60), capture.pointSize.width * 4)
        let newHeight = newWidth * capture.pointSize.height / capture.pointSize.width
        frame.origin.x += (frame.width - newWidth) / 2
        frame.origin.y += (frame.height - newHeight) / 2
        frame.size = NSSize(width: newWidth, height: newHeight)
        setFrame(frame, display: true)
    }

    func closePin() {
        orderOut(nil)
        contentView = nil // releases the image now rather than whenever AppKit lets go of the window
        close()
        PinWindow.open.removeAll { $0 === self }
    }

    func menu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "Save", action: #selector(saveImage), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "Actual Size", action: #selector(actualSize), keyEquivalent: "0").target = self
        let opacity = NSMenuItem(title: "Opacity", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for value in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "\(value)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = value
            item.target = self
            item.state = safeInt((alphaValue * 100).rounded()) == value ? .on : .off
            submenu.addItem(item)
        }
        opacity.submenu = submenu
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Close", action: #selector(closeFromMenu), keyEquivalent: "w").target = self
        return menu
    }

    @objc private func copyImage() { if capture.copyToClipboard() { Toast.show("Copied to clipboard") } }
    @objc private func saveImage() { capture.saveReporting() }
    @objc private func actualSize() {
        var frame = self.frame
        frame.size = capture.pointSize
        setFrame(frame, display: true)
    }
    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func closeFromMenu() { closePin() }
}

private final class PinImageView: NSImageView {
    weak var pin: PinWindow?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pin?.closePin() } else { window?.performDrag(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        pin?.zoom(by: event.scrollingDeltaY > 0 ? 1.06 : 1 / 1.06)
    }

    override func magnify(with event: NSEvent) {
        pin?.zoom(by: 1 + event.magnification)
    }

    override func menu(for event: NSEvent) -> NSMenu? { pin?.menu() }
}
