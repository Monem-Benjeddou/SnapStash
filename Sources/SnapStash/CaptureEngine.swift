import AppKit
import ScreenCaptureKit

/// One display, captured at full resolution the moment a capture starts. Selecting an area crops
/// this frozen image, so what you select is exactly what you saw (menus and hover states included).
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage

    /// Pixels per point in `image` (2 on Retina).
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }

    /// Crops a rect given in this screen's local points (bottom-left origin).
    func crop(_ rect: CGRect) -> CGImage? {
        let pixels = CGRect(x: rect.minX * scale,
                            y: (screen.frame.height - rect.maxY) * scale,
                            width: rect.width * scale,
                            height: rect.height * scale).integral
        return image.cropping(to: pixels)
    }
}

/// A window you can pick in window mode, front to back.
struct WindowTarget {
    let window: SCWindow
    /// In global AppKit coordinates (bottom-left origin).
    let frame: CGRect
    let appName: String
}

enum CaptureError: LocalizedError {
    case noDisplays
    case timedOut
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display could be captured."
        case .timedOut: return "macOS's screen capture service isn't responding. Try again in a moment."
        case .permissionDenied: return "Screen Recording permission is turned off."
        }
    }

    /// Whether `error` means macOS refused the capture because permission is off. This can happen
    /// while SnapStash is running (the switch turned off in System Settings), when the preflight
    /// check still says yes.
    static func isPermissionDenied(_ error: Error) -> Bool {
        if case CaptureError.permissionDenied = error { return true }
        let ns = error as NSError
        return ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userDeclined.rawValue
    }
}

/// Lets exactly one of several racing callers through (thread-safe).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Runs `operation`, giving up after `seconds`. ScreenCaptureKit calls occasionally never return
/// (e.g. while replayd restarts); without this, one stuck call would block every later capture.
/// The stuck call is abandoned, not cancelled: ScreenCaptureKit doesn't support cancellation.
func withTimeout<T>(_ seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let once = Once()
        Task {
            do {
                let value = try await operation()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if once.claim() { continuation.resume(throwing: CaptureError.timedOut) }
        }
    }
}

enum CaptureEngine {
    static func shareableContent() async throws -> SCShareableContent {
        try await withTimeout(8) {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
    }

    /// Captures every display, leaving out SnapStash's own windows (e.g. a previous Quick Access thumbnail).
    /// A display that fails is skipped (you can still capture on the others); it only fails if none work.
    @MainActor
    static func freezeScreens(_ content: SCShareableContent) async throws -> [FrozenScreen] {
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var frozen: [FrozenScreen] = []
        var lastError: Error?
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = Prefs.showCursor
            config.captureResolution = .best
            do {
                let image = try await withTimeout(8) {
                    try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                }
                frozen.append(FrozenScreen(screen: screen, image: image))
            } catch {
                if CaptureError.isPermissionDenied(error) { throw error }
                log.error("Display \(display.displayID) couldn't be captured: \(error.localizedDescription, privacy: .public)")
                lastError = error
            }
        }
        guard !frozen.isEmpty else { throw lastError ?? CaptureError.noDisplays }
        return frozen
    }

    /// Normal app windows on screen, front to back (ScreenCaptureKit's own list has no z-order,
    /// so the order comes from the window server).
    static func windowTargets(_ content: SCShareableContent) -> [WindowTarget] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID,
                  let window = byID[number],
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let app = window.owningApplication, app.processID != ownPID,
                  window.frame.width >= 40, window.frame.height >= 40 else { return nil }
            return WindowTarget(window: window, frame: window.frame.flippedToAppKit, appName: app.applicationName)
        }
    }

    /// Captures one window by itself: nothing covering it, and with its shadow on a transparent
    /// background unless window shadows are turned off.
    static func capture(window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = !Prefs.windowShadow
        config.shouldBeOpaque = false
        return try await withTimeout(8) {
            try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        }
    }
}
