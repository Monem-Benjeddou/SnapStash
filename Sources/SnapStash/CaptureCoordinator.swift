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
            let image = try await CaptureEngine.capture(window: target.window)
            let scale = NSScreen.screens.first { $0.frame.intersects(target.frame) }?.backingScaleFactor ?? 2
            if action == .text {
                await copyText(from: image)
            } else {
                finish(Capture(image: image, scale: scale))
            }
        }
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
        if Prefs.copyToClipboard { capture.copyToClipboard() }
        if Prefs.saveToFolder {
            do {
                try capture.save()
            } catch {
                log.error("Save failed: \(error.localizedDescription, privacy: .public)")
                Toast.show("Couldn't save to \(Prefs.folder.lastPathComponent): \(error.localizedDescription)",
                           symbol: "exclamationmark.triangle.fill")
            }
        }
        if Prefs.showQuickAccess {
            QuickAccess.shared.show(capture)
        } else if Prefs.copyToClipboard {
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
            pasteboard.setString(text, forType: .string)
            let lines = text.split(separator: "\n").count
            Toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text")
        } catch {
            Toast.show("Couldn't read text: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Screen Recording permission: asks once, then explains how to grant it.
    private func ensurePermission() -> Bool {
        if ScreenPermission.isGranted { return true }
        if ScreenPermission.request() { return true }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "SnapStash needs Screen Recording permission"
        alert.informativeText = """
            Turn on SnapStash in System Settings › Privacy & Security › Screen & System Audio Recording, \
            then reopen SnapStash. Captures stay on your Mac.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Reopen SnapStash")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: ScreenPermission.openSettings()
        case .alertSecondButtonReturn: ScreenPermission.relaunch()
        default: break
        }
        return false
    }
}
