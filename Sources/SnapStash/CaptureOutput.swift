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

    /// A small copy for the corner thumbnail. Drawing the full image there would keep a second
    /// full-resolution copy in graphics memory (over 40 MB for a full Retina screen).
    private(set) lazy var thumbnail: NSImage = {
        let maxPixels: CGFloat = 600
        let factor = min(1, maxPixels / CGFloat(max(image.width, image.height, 1)))
        let width = max(Int(CGFloat(image.width) * factor), 1), height = max(Int(CGFloat(image.height) * factor), 1)
        guard factor < 1,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nsImage }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nsImage }
        return NSImage(cgImage: small, size: NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2))
    }()

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

    /// Puts the image on the clipboard as PNG and TIFF. Returns false (and says so) if neither worked.
    @discardableResult
    func copyToClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var ok = false
        if let png = encoded(as: .png) { ok = pasteboard.setData(png, forType: .png) || ok }
        if let tiff = nsImage.tiffRepresentation { ok = pasteboard.setData(tiff, forType: .tiff) || ok }
        if !ok {
            log.error("Couldn't write the capture to the clipboard")
            Toast.show("Couldn't copy to the clipboard", symbol: "exclamationmark.triangle.fill")
        }
        return ok
    }

    /// Saves into the capture folder (once; later calls return the same file). If that folder can't
    /// be used (an ejected drive, a deleted folder, no write access), saves to the default folder
    /// instead, so a capture is never lost to a folder problem.
    @discardableResult
    func save() throws -> URL {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        guard let data = encoded() else { throw CocoaError(.fileWriteUnknown) }
        do {
            savedURL = try write(data, into: Prefs.folder)
        } catch where Prefs.folder.standardizedFileURL != Prefs.defaultFolder.standardizedFileURL {
            log.error("Save to \(Prefs.folder.path, privacy: .public) failed, using the default folder: \(error.localizedDescription, privacy: .public)")
            savedURL = try write(data, into: Prefs.defaultFolder)
        }
        return savedURL!
    }

    private func write(_ data: Data, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = Prefs.format.fileExtension
        var url = folder.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(fileName.replacingOccurrences(of: ".\(ext)", with: " \(counter).\(ext)"))
            counter += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Saves and tells you how it went. `quiet` skips the message when everything went as expected
    /// (e.g. right after a capture, where Quick Access already shows it). Returns whether it was saved.
    @discardableResult
    func saveReporting(quiet: Bool = false) -> Bool {
        do {
            let url = try save()
            let folder = url.deletingLastPathComponent()
            if folder.standardizedFileURL != Prefs.folder.standardizedFileURL {
                Toast.show("“\(Prefs.folder.lastPathComponent)” isn't available, so this was saved to Pictures › SnapStash",
                           symbol: "exclamationmark.triangle.fill")
            } else if !quiet {
                Toast.show("Saved to \(folder.lastPathComponent)")
            }
            return true
        } catch {
            log.error("Save failed: \(error.localizedDescription, privacy: .public)")
            Toast.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            return false
        }
    }

    /// Where drag-out copies go; emptied at launch so they don't pile up.
    static let dragFolder = FileManager.default.temporaryDirectory.appendingPathComponent("SnapStash Drags", isDirectory: true)

    /// A file for dragging into other apps: the saved file if there is one, otherwise a temporary copy.
    func fileForDragging() -> URL? {
        if let savedURL, FileManager.default.fileExists(atPath: savedURL.path) { return savedURL }
        do {
            try FileManager.default.createDirectory(at: Self.dragFolder, withIntermediateDirectories: true)
            let url = Self.dragFolder.appendingPathComponent(fileName)
            guard let data = encoded() else { return nil }
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            log.error("Couldn't prepare a file for dragging: \(error.localizedDescription, privacy: .public)")
            return nil
        }
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
            // Vision can report a failure both through the handler and by throwing from perform();
            // resuming a continuation twice would crash, so only the first report counts.
            let once = Once()
            let request = VNRecognizeTextRequest { request, error in
                guard once.claim() else { return }
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
                    if once.claim() { continuation.resume(throwing: error) }
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
        panel?.close() // close, not just order out: AppKit keeps ordered-out windows alive

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

        let work = DispatchWorkItem { MainActor.assumeIsolated { Toast.panel?.close(); Toast.panel = nil } }
        hideWork = work
        // Problems stay up long enough to read.
        DispatchQueue.main.asyncAfter(deadline: .now() + (symbol.contains("exclamation") ? 4 : 1.8), execute: work)
    }
}
