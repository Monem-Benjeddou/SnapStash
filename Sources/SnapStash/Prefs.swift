import AppKit
import Carbon.HIToolbox
import os

let log = Logger(subsystem: "dev.snapstash.SnapStash", category: "capture")

/// The things a shortcut can start.
enum CaptureAction: String, CaseIterable, Identifiable {
    case area, window, screen, text

    var id: String { rawValue }
    var hotKeyID: UInt32 { UInt32(CaptureAction.allCases.firstIndex(of: self)! + 1) }

    var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .screen: return "Capture Screen"
        case .text: return "Copy Text from Screen"
        }
    }

    var symbol: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .screen: return "display"
        case .text: return "text.viewfinder"
        }
    }

    /// Mirrors the system's ⇧⌘3/4/5 with ⌥ instead of ⌘, so it doesn't fight with them.
    var defaultShortcut: Shortcut {
        let mods = optionKey | shiftKey
        switch self {
        case .area: return Shortcut(keyCode: kVK_ANSI_4, modifiers: mods)
        case .window: return Shortcut(keyCode: kVK_ANSI_5, modifiers: mods)
        case .screen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: mods)
        case .text: return Shortcut(keyCode: kVK_ANSI_2, modifiers: mods)
        }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpeg
    var id: String { rawValue }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}

enum Prefs {
    static let copyToClipboardKey = "copyToClipboard"
    static let saveToFolderKey = "saveToFolder"
    static let showQuickAccessKey = "showQuickAccess"
    static let quickAccessSecondsKey = "quickAccessSeconds"
    static let folderKey = "saveFolder"
    static let formatKey = "imageFormat"
    static let windowShadowKey = "windowShadow"
    static let showCursorKey = "showCursor"
    static let playSoundKey = "playSound"
    static let showInDockKey = "showInDock"

    private static var defaults: UserDefaults { .standard }
    private static func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }

    static var copyToClipboard: Bool { bool(copyToClipboardKey, true) }
    static var saveToFolder: Bool { bool(saveToFolderKey, true) }
    static var showQuickAccess: Bool { bool(showQuickAccessKey, true) }
    /// 0 = stay until closed.
    static var quickAccessSeconds: Int { defaults.object(forKey: quickAccessSecondsKey) as? Int ?? 8 }
    static var windowShadow: Bool { bool(windowShadowKey, true) }
    static var showCursor: Bool { bool(showCursorKey, false) }
    static var playSound: Bool { bool(playSoundKey, true) }
    static var showInDock: Bool { bool(showInDockKey, true) }
    static var format: ImageFormat { defaults.string(forKey: formatKey).flatMap(ImageFormat.init(rawValue:)) ?? .png }

    static let defaultFolder = (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures", isDirectory: true))
        .appendingPathComponent("SnapStash", isDirectory: true)

    static var folder: URL {
        get { defaults.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder }
        set { defaults.set(newValue.path, forKey: folderKey) }
    }

    static func shortcut(for action: CaptureAction) -> Shortcut? {
        let key = "shortcut.\(action.rawValue)"
        if defaults.object(forKey: key) as? Bool == false { return nil } // explicitly cleared
        guard let data = defaults.data(forKey: key) else { return action.defaultShortcut }
        guard let saved = try? JSONDecoder().decode(Shortcut.self, from: data), saved.isValid else {
            log.error("Saved shortcut for \(action.rawValue, privacy: .public) is unreadable; using the default")
            return action.defaultShortcut
        }
        return saved
    }

    static func setShortcut(_ shortcut: Shortcut?, for action: CaptureAction) {
        let key = "shortcut.\(action.rawValue)"
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set(false, forKey: key)
        }
    }
}

/// Screen Recording permission, which ScreenCaptureKit needs for everything here.
enum ScreenPermission {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards macOS only lists the app in System Settings.
    static func request() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        let urls = ["x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy"]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Restarts the app; macOS only applies a newly granted Screen Recording permission after a relaunch.
    /// Only quits once the reopen is scheduled, so a failure can't leave SnapStash closed.
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Waits until this process has fully exited, so the new one doesn't see it and hand over to it.
        task.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; open \"$0\"",
                          path, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            log.error("Relaunch failed: \(error.localizedDescription, privacy: .public)")
            Toast.show("Couldn't restart SnapStash. Quit it from the menu bar and open it again.",
                       symbol: "exclamationmark.triangle.fill")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// The screen under the mouse pointer.
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

extension CGRect {
    /// Converts a rect in global screen coordinates with a top-left origin (Core Graphics, ScreenCaptureKit)
    /// to AppKit's bottom-left origin.
    var flippedToAppKit: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }
}
