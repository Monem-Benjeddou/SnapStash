import AppKit
import ScreenCaptureKit

/// Runs a capture from start to finish: permission, freezing the screens, selection, and output.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: SelectionOverlay?

    /// The same shutter sound macOS's own screenshots make.
    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop")
    }()
    private var isCapturing = false

    func start(_ action: CaptureAction) {
        guard !isCapturing else { return }
        guard ensurePermission() else { return }
        isCapturing = true
        // SnapStash's own windows (e.g. earlier thumbnails) are left out of the frozen screens, so
        // nothing needs hiding first.
        Task {
            defer { isCapturing = false }
            do {
                try await run(action)
            } catch where CaptureError.isPermissionDenied(error) {
                // Turned off while SnapStash was running: the setup card explains how to turn it back on.
                log.error("Capture refused: Screen Recording permission is off")
                AppState.shared.permissionLost = true
                MainWindow.shared.show()
            } catch {
                log.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                Toast.show("Capture failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func run(_ action: CaptureAction) async throws {
        let content = try await CaptureEngine.shareableContent()
        let frozen = try await CaptureEngine.freezeScreens(content)

        if action == .screen {
            let screen = NSScreen.underMouse
            guard let shot = frozen.first(where: { $0.screen == screen }) ?? frozen.first else { return }
            finish(Capture(image: shot.image, scale: shot.scale))
            return
        }

        let windows = CaptureEngine.windowTargets(content)
        let result = await select(frozen: frozen, windows: windows, windowMode: action == .window)
        switch result {
        case .cancelled:
            return
        case .area(let screen, let rect):
            guard let image = screen.crop(rect) else { return }
            if action == .text {
                await copyText(from: image)
            } else {
                finish(Capture(image: image, scale: screen.scale))
            }
        case .window(let target):
            let image: CGImage
            let scale: CGFloat
            do {
                image = try await CaptureEngine.capture(window: target.window)
                scale = NSScreen.screens.first { $0.frame.intersects(target.frame) }?.backingScaleFactor ?? 2
            } catch where !CaptureError.isPermissionDenied(error) {
                // The window closed or moved in the meantime: use what was on screen when you picked it.
                log.error("Window capture failed, using the frozen screen: \(error.localizedDescription, privacy: .public)")
                guard let (cropped, frozenScale) = Self.crop(target.frame, from: frozen) else { throw error }
                image = cropped
                scale = frozenScale
            }
            if action == .text {
                await copyText(from: image)
            } else {
                finish(Capture(image: image, scale: scale))
            }
        }
    }

    /// Crops a global AppKit rect out of the frozen screen it's mostly on.
    private static func crop(_ rect: CGRect, from frozen: [FrozenScreen]) -> (CGImage, CGFloat)? {
        let best = frozen.max { a, b in
            let ia = a.screen.frame.intersection(rect), ib = b.screen.frame.intersection(rect)
            return ia.width * ia.height < ib.width * ib.height
        }
        guard let best else { return nil }
        let visible = best.screen.frame.intersection(rect)
        guard !visible.isEmpty else { return nil }
        let local = visible.offsetBy(dx: -best.screen.frame.minX, dy: -best.screen.frame.minY)
        return best.crop(local).map { ($0, best.scale) }
    }

    private func select(frozen: [FrozenScreen], windows: [WindowTarget], windowMode: Bool) async -> SelectionResult {
        await withCheckedContinuation { continuation in
            let overlay = SelectionOverlay(windowMode: windowMode)
            self.overlay = overlay
            overlay.begin(frozen: frozen, windows: windows) { [weak self] result in
                self?.overlay = nil
                continuation.resume(returning: result)
            }
        }
    }

    /// Applies the after-capture settings: copy, save, and show Quick Access.
    private func finish(_ capture: Capture) {
        if Prefs.playSound { Self.shutterSound?.play() }
        let copied = Prefs.copyToClipboard && capture.copyToClipboard()
        // A failed save says so; the capture is still in Quick Access (and on the clipboard) to retry.
        let saved = Prefs.saveToFolder && capture.saveReporting(quiet: true)
        if Prefs.showQuickAccess || (Prefs.saveToFolder && !saved && !copied) {
            QuickAccess.shared.show(capture)
        } else if copied && !(Prefs.saveToFolder && !saved) {
            Toast.show("Copied to clipboard")
        }
    }

    func copyText(from image: CGImage) async {
        do {
            let text = try await TextRecognizer.recognize(image)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                Toast.show("No text found", symbol: "exclamationmark.triangle.fill")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                Toast.show("Couldn't copy the text to the clipboard", symbol: "exclamationmark.triangle.fill")
                return
            }
            let lines = text.split(separator: "\n").count
            Toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text")
        } catch {
            Toast.show("Couldn't read text: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Without Screen Recording permission, opens the main window, whose card walks through granting it.
    /// No alerts: one calm place to fix it.
    private func ensurePermission() -> Bool {
        if ScreenPermission.isGranted && !AppState.shared.permissionLost { return true }
        MainWindow.shared.show()
        return false
    }
}
