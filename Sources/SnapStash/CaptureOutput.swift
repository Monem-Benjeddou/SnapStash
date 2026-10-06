import AppKit
import UniformTypeIdentifiers
@preconcurrency import Vision

/// A finished capture and everything you can do with it.
@MainActor
final class Capture: Identifiable {
    let id = UUID()
    let image: CGImage
    /// Points per pixel: 2-pixel-per-point Retina captures show at their real size.
    let scale: CGFloat
    let date = Date()
    private(set) var savedURL: URL?

    init(image: CGImage, scale: CGFloat) {
        self.image = image
        self.scale = max(scale, 1)
    }

    var pointSize: NSSize { NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }

    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }

    var fileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "SnapStash \(formatter.string(from: date)).\(Prefs.format.fileExtension)"
    }

    func encoded(as format: ImageFormat = Prefs.format) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = pointSize // keeps the Retina DPI, so it isn't pasted at double size
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    func copyToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = encoded(as: .png) { pasteboard.setData(png, forType: .png) }
        if let tiff = nsImage.tiffRepresentation { pasteboard.setData(tiff, forType: .tiff) }
    }

    /// Saves into the capture folder (once; later calls return the same file).
    @discardableResult
    func save() throws -> URL {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        let folder = Prefs.folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = encoded() else { throw CocoaError(.fileWriteUnknown) }
        var url = folder.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(fileName.replacingOccurrences(of: ".\(Prefs.format.fileExtension)",
                                                                            with: " \(counter).\(Prefs.format.fileExtension)"))
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        savedURL = url
        return url
    }

    /// A file for dragging into other apps: the saved file if there is one, otherwise a temporary copy.
    func fileForDragging() -> URL? {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        guard let data = encoded(), (try? data.write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }

    /// Asks where to save, for "Save As…".
    func saveAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [Prefs.format == .png ? .png : .jpeg]
        panel.directoryURL = Prefs.folder
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url, let data = encoded() else { return }
        do {
            try data.write(to: url, options: .atomic)
            savedURL = url
            Toast.show("Saved", symbol: "checkmark.circle.fill")
        } catch {
            Toast.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }
}

enum TextRecognizer {
    /// Recognizes text in reading order, one line per line of text.
    static func recognize(_ image: CGImage) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // Vision's coordinates have a bottom-left origin: sort top to bottom, then left to right.
                let lines = observations
                    .sorted { abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.01
                        ? $0.boundingBox.midY > $1.boundingBox.midY
                        : $0.boundingBox.minX < $1.boundingBox.minX }
                    .compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try VNImageRequestHandler(cgImage: image).perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// A short message near the bottom of the screen, like the system volume HUD.
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = symbol.contains("exclamation") ? .systemOrange : .systemGreen
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        let size = stack.fittingSize
        let width = min(size.width, 520)
        guard let screen = NSScreen.underMouse else { return }
        let frame = NSRect(x: screen.visibleFrame.midX - width / 2, y: screen.visibleFrame.minY + 80,
                           width: width, height: size.height)
        let toast = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        toast.level = .statusBar
        toast.isOpaque = false
        toast.backgroundColor = .clear
        toast.hasShadow = true
        toast.ignoresMouseEvents = true
        toast.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        toast.contentView = effect
        toast.orderFrontRegardless()
        panel = toast

        let work = DispatchWorkItem { MainActor.assumeIsolated { Toast.panel?.orderOut(nil); Toast.panel = nil } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
