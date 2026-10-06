import AppKit
import SwiftUI

/// The main SnapStash window. AppKit-managed so it can be opened from anywhere: the menu bar,
/// a Dock click, or a capture attempted before permission is granted.
@MainActor
final class MainWindow {
    static let shared = MainWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "SnapStash"
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 460)
            // Open on whichever Space you're in (including next to a full-screen app), not back on the desktop.
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            let hosting = NSHostingController(rootView: HomeView(state: .shared, library: .shared))
            hosting.sizingOptions = [.minSize] // the content sets a minimum, not the window's size
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 920, height: 640))
            if !window.setFrameUsingName("SnapStashMain") { window.center() }
            window.setFrameAutosaveName("SnapStashMain")
            self.window = window
        }
        if !AppState.shared.galleryPaused { CaptureLibrary.shared.reload() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var state: AppState
    @ObservedObject var library: CaptureLibrary
    @State private var hasPermission = ScreenPermission.isGranted
    @AppStorage("onboardingComplete") private var onboardingComplete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if !hasPermission || state.permissionLost {
                    PermissionCard(lost: state.permissionLost && hasPermission)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if !onboardingComplete {
                    ReadyCard(state: state) { withAnimation(.snappy) { onboardingComplete = true } }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                CaptureButtons(state: state, enabled: hasPermission && !state.permissionLost)
                if state.galleryPaused {
                    SafeModeCard { state.resumeGallery() }
                } else {
                    Gallery(library: library)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // macOS gives no notification when the permission changes, so poll, but only while waiting for
        // it: once granted there's nothing to watch (a later revocation shows up when a capture fails).
        .task(id: hasPermission) {
            while !hasPermission, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if ScreenPermission.isGranted { withAnimation(.snappy) { hasPermission = true } }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("SnapStash").font(.system(size: 26, weight: .bold, design: .rounded))
                Text("Capture anything on your screen, then copy, save, drag or pin it.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                try? FileManager.default.createDirectory(at: Prefs.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Prefs.folder)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .controlSize(.large)
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            .controlSize(.large)
        }
        .padding(.top, 8)
    }
}

// MARK: - Permission

/// Shown only until Screen Recording is allowed. One button does the asking; no alerts anywhere else.
private struct PermissionCard: View {
    /// Was working, then got turned off (or macOS forgot it, e.g. after an update): different words, same fix.
    var lost = false
    @State private var asked = UserDefaults.standard.bool(forKey: "askedScreenPermission")

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.gradient)
                Image(systemName: "rectangle.dashed.badge.record")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lost ? "Screen Recording was turned off" : "One step before your first capture")
                        .font(.title3.weight(.semibold))
                    Text(lost
                         ? "macOS stopped SnapStash from capturing. Turn Screen Recording back on for SnapStash, then restart it."
                         : "macOS asks every screenshot app for Screen Recording access. SnapStash only looks at your screen when you capture, and nothing ever leaves your Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Step(number: 1, text: lost ? "Click **Open System Settings** below." : "Click **Allow Screen Recording** below. System Settings opens.",
                         done: asked && !lost)
                    Step(number: 2, text: "Turn on the switch next to **SnapStash**.", done: false)
                    Step(number: 3, text: "When macOS offers **Quit & Reopen**, click it. (Or use **Restart SnapStash** here.)", done: false)
                }

                HStack(spacing: 10) {
                    Button {
                        allow()
                    } label: {
                        Text(lost ? "Open System Settings" : "Allow Screen Recording").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if asked || lost {
                        Button("Restart SnapStash") { ScreenPermission.relaunch() }
                            .controlSize(.large)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.accentColor.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor.opacity(0.25)))
    }

    private func allow() {
        // The system prompt appears only the first time; after that, go straight to the right pane.
        if lost || !ScreenPermission.request() { ScreenPermission.openSettings() }
        UserDefaults.standard.set(true, forKey: "askedScreenPermission")
        withAnimation(.snappy) { asked = true }
    }

    private struct Step: View {
        let number: Int
        let text: LocalizedStringKey
        let done: Bool

        var body: some View {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(done ? Color.green : Color.secondary.opacity(0.18))
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    } else {
                        Text("\(number)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                Text(text)
            }
        }
    }
}

// MARK: - First run

/// Shown once setup is done: the three things a new user needs to know, and a way to try it.
private struct ReadyCard: View {
    @ObservedObject var state: AppState
    let dismiss: () -> Void

    private var areaKeys: String {
        _ = state.shortcutsVersion
        return Prefs.shortcut(for: .area)?.display ?? "⌥⇧4"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 28)).foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all set").font(.title3.weight(.semibold))
                    Text("Here's everything you need to know.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide this")
            }

            HStack(alignment: .top, spacing: 14) {
                Tip(symbol: "keyboard", title: "Press \(areaKeys) anywhere",
                    text: "Drag over what you want. Click once to grab a whole window instead.")
                Tip(symbol: "rectangle.bottomhalf.inset.filled", title: "It's already copied",
                    text: "A thumbnail appears in the corner. Paste anywhere, drag it into an app, or pin it.")
                Tip(symbol: "menubar.arrow.up.rectangle", title: "SnapStash lives in the menu bar",
                    text: "Close this window anytime. Click the camera icon at the top of your screen to come back.")
            }

            HStack(spacing: 10) {
                Button {
                    CaptureCoordinator.shared.start(.area)
                } label: {
                    Label("Try it now", systemImage: "rectangle.dashed").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Got it", action: dismiss).controlSize(.large)
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color.green.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.green.opacity(0.25)))
    }

    private struct Tip: View {
        let symbol: String
        let title: String
        let text: String

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).font(.title2).foregroundStyle(Color.accentColor).frame(height: 28)
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        }
    }
}

// MARK: - Capture buttons

private struct CaptureButtons: View {
    @ObservedObject var state: AppState
    let enabled: Bool

    var body: some View {
        HStack(spacing: 14) {
            ForEach(CaptureAction.allCases) { action in
                CaptureTile(action: action, shortcut: shortcut(action), enabled: enabled,
                            conflict: state.shortcutConflicts.contains(action))
            }
        }
    }

    private func shortcut(_ action: CaptureAction) -> String? {
        _ = state.shortcutsVersion
        return Prefs.shortcut(for: action)?.display
    }
}

private struct CaptureTile: View {
    let action: CaptureAction
    let shortcut: String?
    let enabled: Bool
    let conflict: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            CaptureCoordinator.shared.start(action)
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: action.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(enabled ? Color.accentColor : .secondary)
                    .frame(height: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(shortTitle).font(.headline)
                    if conflict {
                        Label("Shortcut taken", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .help("Another app uses this shortcut. Choose a different one in Settings › Shortcuts.")
                    } else if let shortcut {
                        Text(shortcut)
                            .font(.system(.caption, design: .rounded).weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(hovering && enabled ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(hovering && enabled ? 0.12 : 0.04), radius: hovering ? 8 : 3, y: 2)
            .scaleEffect(hovering && enabled ? 1.015 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .help(enabled ? action.title : "Allow Screen Recording first")
    }

    private var shortTitle: String {
        switch action {
        case .area: return "Area"
        case .window: return "Window"
        case .screen: return "Full Screen"
        case .text: return "Copy Text"
        }
    }
}

// MARK: - Gallery

private struct Gallery: View {
    @ObservedObject var library: CaptureLibrary
    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Captures").font(.title3.weight(.semibold))
                if !library.items.isEmpty {
                    Text("\(library.items.count)").foregroundStyle(.tertiary)
                }
                Spacer()
                Text(Prefs.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let problem = library.folderProblem {
                FolderProblem(message: problem, library: library)
            } else if library.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("No captures yet").font(.headline)
                    Text("Saved captures appear here. Press \(Prefs.shortcut(for: .area)?.display ?? "⌥⇧4") anywhere to capture an area.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .background(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.3)))
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(library.items.prefix(300)) { item in
                        GalleryCard(item: item, library: library)
                    }
                }
            }
        }
    }
}

private struct GalleryCard: View {
    let item: CaptureLibrary.Item
    @ObservedObject var library: CaptureLibrary
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(8)
                } else {
                    ProgressView().controlSize(.small)
                }
                if hovering {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35))
                    HStack(spacing: 8) {
                        IconButton(symbol: "doc.on.doc", help: "Copy") { library.copy(item) }
                        IconButton(symbol: "pin", help: "Pin to screen") { library.pin(item) }
                        IconButton(symbol: "text.viewfinder", help: "Copy text") { library.copyText(item) }
                        IconButton(symbol: "folder", help: "Show in Finder") { library.reveal(item) }
                    }
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 1) {
                Text(item.date.formatted(date: .abbreviated, time: .shortened)).font(.callout.weight(.medium))
                Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hovering = inside } }
        .onTapGesture(count: 2) { library.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { library.open(item) }
            Button("Copy") { library.copy(item) }
            Button("Copy Text") { library.copyText(item) }
            Button("Pin to Screen") { library.pin(item) }
            Button("Show in Finder") { library.reveal(item) }
            Divider()
            Button("Move to Trash", role: .destructive) { library.trash(item) }
        }
        .task(id: item.url) { thumbnail = await ThumbnailCache.shared.load(item.url) }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.92)))
                .foregroundStyle(.black)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The capture folder can't be used: what happened, and the two ways out.
private struct FolderProblem: View {
    let message: String
    @ObservedObject var library: CaptureLibrary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title3)
            VStack(alignment: .leading, spacing: 10) {
                Text(message).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Choose Another Folder…") { chooseFolder() }
                    if library.usesCustomFolder {
                        Button("Use Pictures › SnapStash") { library.useDefaultFolder() }
                    }
                    Button("Try Again") { library.start() }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.3)))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Prefs.folder = url
        library.start()
    }
}

/// After SnapStash crashed twice right after starting: says what was left off and how to turn it back on.
private struct SafeModeCard: View {
    let resume: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "lifepreserver").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 10) {
                Text("SnapStash started in safe mode").font(.headline)
                Text("It quit unexpectedly twice right after starting, so your recent captures aren't loaded this time. Capturing works as usual. If it happens again after loading them, a damaged image in your capture folder is the likely cause.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Load Recent Captures", action: resume).buttonStyle(.borderedProminent)
                    Button("Open Captures Folder") { NSWorkspace.shared.open(Prefs.folder) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.orange.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.orange.opacity(0.3)))
    }
}
