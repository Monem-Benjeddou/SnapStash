import AppKit
import ImageIO

private let imageFileExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif"]

/// The captures saved in the capture folder, newest first. Watches the folder so the gallery stays
/// current whether a capture comes from SnapStash or a file is added or removed in Finder.
@MainActor
final class CaptureLibrary: ObservableObject {
    static let shared = CaptureLibrary()

    struct Item: Identifiable, Hashable {
        let url: URL
        let date: Date
        let bytes: Int
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var folderProblem: String?

    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let library = CaptureLibrary.shared
                if library.watchedPath != Prefs.folder.path { library.start() }
            }
        }
    }

    /// (Re)starts watching the current capture folder.
    func start() {
        watcher?.cancel()
        watcher = nil
        let folder = Prefs.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        watchedPath = folder.path
        let descriptor = Darwin.open(folder.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                                   queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { CaptureLibrary.shared.reload() } }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watcher = source
        }
        reload()
    }

    func reload() {
        let folder = Prefs.folder
        Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey, .isRegularFileKey]
            do {
                let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles])
                let items = urls.compactMap { url -> Item? in
                    guard imageFileExtensions.contains(url.pathExtension.lowercased()),
                          let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
                    return Item(url: url, date: values.creationDate ?? .distantPast, bytes: values.fileSize ?? 0)
                }
                .sorted { $0.date > $1.date }
                await MainActor.run {
                    let library = CaptureLibrary.shared
                    if library.items != items { library.items = items }
                    library.folderProblem = nil
                }
            } catch {
                await MainActor.run {
                    CaptureLibrary.shared.items = []
                    CaptureLibrary.shared.folderProblem = "Can't read \(folder.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: Actions on saved files

    func copy(_ item: Item) {
        guard let image = NSImage(contentsOf: item.url) else { return missing(item) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        Toast.show("Copied to clipboard")
    }

    func pin(_ item: Item) {
        guard let capture = Self.capture(from: item.url) else { return missing(item) }
        PinWindow.show(capture)
    }

    func copyText(_ item: Item) {
        guard let capture = Self.capture(from: item.url) else { return missing(item) }
        Task { await CaptureCoordinator.shared.copyText(from: capture.image) }
    }

    func reveal(_ item: Item) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }

    func open(_ item: Item) { NSWorkspace.shared.open(item.url) }

    func trash(_ item: Item) {
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            items.removeAll { $0 == item }
        } catch {
            Toast.show("Couldn't move to Trash: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    private func missing(_ item: Item) {
        Toast.show("\(item.url.lastPathComponent) can't be opened", symbol: "exclamationmark.triangle.fill")
        reload()
    }

    /// Rebuilds a Capture from a file, keeping its Retina scale (from its DPI).
    static func capture(from url: URL) -> Capture? {
        guard let rep = NSImageRep(contentsOf: url) as? NSBitmapImageRep, let image = rep.cgImage else { return nil }
        let scale = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        return Capture(image: image, scale: scale)
    }
}

/// Small, cached thumbnails decoded off the main thread.
final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    @MainActor
    func load(_ url: URL, maxPixels: Int = 640) async -> NSImage? {
        if let hit = cached(url) { return hit }
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            ] as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
