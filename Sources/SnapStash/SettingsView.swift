import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureSettings()
                .tabItem { Label("Captures", systemImage: "camera.viewfinder") }
            ShortcutSettings(state: state)
                .tabItem { Label("Shortcuts", systemImage: "command") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.showInDockKey) private var showInDock = true
    @AppStorage(Prefs.playSoundKey) private var playSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in Dock while a window is open", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in DockIcon.shared.update() }
                Toggle("Play a sound when capturing", isOn: $playSound)
            }

            Section {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    LabeledContent("Screen Recording") {
                        if ScreenPermission.isGranted {
                            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack {
                                Button("Open System Settings") { ScreenPermission.openSettings() }
                                Button("Reopen SnapStash") { ScreenPermission.relaunch() }
                            }
                        }
                    }
                }
            } header: {
                Text("Permission")
            } footer: {
                Text("SnapStash needs Screen Recording permission to capture. Everything stays on your Mac. macOS applies a newly granted permission after SnapStash reopens.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct CaptureSettings: View {
    @AppStorage(Prefs.copyToClipboardKey) private var copyToClipboard = true
    @AppStorage(Prefs.saveToFolderKey) private var saveToFolder = true
    @AppStorage(Prefs.showQuickAccessKey) private var showQuickAccess = true
    @AppStorage(Prefs.quickAccessSecondsKey) private var quickAccessSeconds = 8
    @AppStorage(Prefs.formatKey) private var format = ImageFormat.png
    @AppStorage(Prefs.windowShadowKey) private var windowShadow = true
    @AppStorage(Prefs.showCursorKey) private var showCursor = false
    @State private var folder = Prefs.folder

    var body: some View {
        Form {
            Section("After capturing") {
                Toggle("Copy to clipboard", isOn: $copyToClipboard)
                Toggle("Save to folder", isOn: $saveToFolder)
                Toggle("Show Quick Access thumbnail", isOn: $showQuickAccess)
                if showQuickAccess {
                    Picker("Hide thumbnail after", selection: $quickAccessSeconds) {
                        Text("5 seconds").tag(5)
                        Text("8 seconds").tag(8)
                        Text("15 seconds").tag(15)
                        Text("Never").tag(0)
                    }
                }
            }

            Section("Saving") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Picker("Format", selection: $format) {
                    Text("PNG (lossless)").tag(ImageFormat.png)
                    Text("JPEG (smaller)").tag(ImageFormat.jpeg)
                }
            }

            Section("Capturing") {
                Toggle("Include the window shadow in window captures", isOn: $windowShadow)
                Toggle("Show the mouse pointer in captures", isOn: $showCursor)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.folder = url
        folder = url
    }
}

private struct ShortcutSettings: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                ForEach(CaptureAction.allCases) { action in
                    LabeledContent {
                        ShortcutRecorder(action: action, state: state)
                    } label: {
                        Label(action.title, systemImage: action.symbol)
                    }
                    if state.shortcutConflicts.contains(action) {
                        Label("This shortcut is used by another app. Choose a different one.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new keys. Shortcuts need ⌘, ⌥ or ⌃. In the capture screen: drag for an area, click for a window, Space to switch, Shift for a square, Esc to cancel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Restore Default Shortcuts") {
                    for action in CaptureAction.allCases { Prefs.setShortcut(action.defaultShortcut, for: action) }
                    state.registerShortcuts()
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click to record a new shortcut; Esc cancels, Delete clears it.
private struct ShortcutRecorder: View {
    let action: CaptureAction
    @ObservedObject var state: AppState
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(label)
                .font(.system(.body, design: .rounded).weight(.medium))
                .frame(minWidth: 110)
        }
        .buttonStyle(.bordered)
        .tint(recording ? .accentColor : nil)
        .onDisappear { stop() }
    }

    private var label: String {
        _ = state.shortcutsVersion
        if recording { return "Press keys…" }
        return Prefs.shortcut(for: action)?.display ?? "None"
    }

    private func start() {
        // Pause global shortcuts while recording so pressing the current one doesn't start a capture.
        for action in CaptureAction.allCases { HotKeyCenter.shared.unregister(id: action.hotKeyID) }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case 53: stop(); return nil                                       // esc: keep the old one
            case 51, 117: Prefs.setShortcut(nil, for: action); stop(); return nil // delete: clear
            default:
                guard let shortcut = Shortcut(event: event) else { NSSound.beep(); return nil }
                Prefs.setShortcut(shortcut, for: action)
                stop()
                return nil
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            state.registerShortcuts()
        }
    }
}
