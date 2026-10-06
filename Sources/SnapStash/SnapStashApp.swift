import ServiceManagement
import SwiftUI

/// App-wide state the UI watches.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    /// Actions whose shortcut couldn't be registered (usually taken by another app).
    @Published var shortcutConflicts: Set<CaptureAction> = []
    @Published var shortcutsVersion = 0

    func registerShortcuts() {
        var conflicts: Set<CaptureAction> = []
        for action in CaptureAction.allCases {
            let ok = HotKeyCenter.shared.register(id: action.hotKeyID, shortcut: Prefs.shortcut(for: action)) {
                CaptureCoordinator.shared.start(action)
            }
            if !ok { conflicts.insert(action) }
        }
        shortcutConflicts = conflicts
        shortcutsVersion += 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["NSQuitAlwaysKeepsWindows": false])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            DockIcon.shared.isEnabled = { Prefs.showInDock }
            DockIcon.shared.start()
            AppState.shared.registerShortcuts()
            CaptureLibrary.shared.start()
            // First launch, permission still missing, or just set up: open the window so the next step
            // is right there (granting permission needs a restart, so this also catches the relaunch).
            let onboarded = UserDefaults.standard.bool(forKey: "onboardingComplete")
            if UserDefaults.standard.object(forKey: "hasLaunched") == nil || !ScreenPermission.isGranted || !onboarded {
                UserDefaults.standard.set(true, forKey: "hasLaunched")
                MainWindow.shared.show()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon (or opening the app again from Finder) shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        MainActor.assumeIsolated { MainWindow.shared.show() }
        return true
    }
}

@main
struct SnapStashApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra("SnapStash", systemImage: "camera.viewfinder") {
            MenuBarMenu(state: state)
        }

        Settings {
            SettingsView(state: state)
        }
    }
}

private struct MenuBarMenu: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button("Open SnapStash") { MainWindow.shared.show() }
        Divider()
        ForEach(CaptureAction.allCases) { action in
            Button {
                CaptureCoordinator.shared.start(action)
            } label: {
                Label(title(action), systemImage: action.symbol)
            }
        }
        Divider()
        Button("Open Captures Folder") {
            try? FileManager.default.createDirectory(at: Prefs.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Prefs.folder)
        }
        if !ScreenPermission.isGranted {
            Button("Set Up Screen Recording…") { MainWindow.shared.show() }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit SnapStash") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Menu items can't show a custom global shortcut natively, so it goes in the title.
    private func title(_ action: CaptureAction) -> String {
        _ = state.shortcutsVersion
        guard let shortcut = Prefs.shortcut(for: action) else { return action.title }
        return "\(action.title)    \(shortcut.display)"
    }
}
