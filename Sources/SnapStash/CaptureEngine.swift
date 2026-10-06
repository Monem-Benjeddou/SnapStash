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

    var errorDescription: String? {
        switch self {
        case .noDisplays: return "No display could be captured."
        }
    }
}

enum CaptureEngine {
    static func shareableContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Captures every display, leaving out SnapStash's own windows (e.g. a previous Quick Access thumbnail).
    @MainActor
    static func freezeScreens(_ content: SCShareableContent) async throws -> [FrozenScreen] {
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var frozen: [FrozenScreen] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: { $0.displayID == display.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.width = Int(filter.contentRect.width * scale)
            config.height = Int(filter.contentRect.height * scale)
            config.showsCursor = Prefs.showCursor
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            frozen.append(FrozenScreen(screen: screen, image: image))
        }
        guard !frozen.isEmpty else { throw CaptureError.noDisplays }
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
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
