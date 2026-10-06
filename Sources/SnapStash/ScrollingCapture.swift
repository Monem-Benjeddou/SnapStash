import AppKit
import ScreenCaptureKit
import SwiftUI

/// Joins frames of a scrolling area into one tall image. Each new frame is matched against the
/// last one it accepted: where its rows line up shows how far the content scrolled, and only the
/// newly revealed rows are added. Rows that stay put (sticky headers and footers) are kept once.
///
/// Not thread-safe by itself: call it from one queue at a time.
final class ScrollStitcher: @unchecked Sendable {
    enum Outcome: Equatable {
        case added(rows: Int)
        case unchanged
        /// No overlap with the previous frame: scrolled too far between frames, or scrolled up.
        case lost
    }

    /// Longest result, in pixels; beyond this, frames are ignored.
    static let maximumHeight = 20_000
    /// Columns averaged per row for matching.
    private static let columns = 64

    private(set) var height = 0
    private var width = 0
    private var frameHeight = 0
    private var first: CGImage?
    /// What each accepted frame added: its bottom rows, from the newly revealed content down to the
    /// frame's end, plus how far it scrolled and how tall the still footer looked in it.
    private var pieces: [(image: CGImage, shift: Int, footer: Int)] = []
    private var previous: (image: CGImage, signature: [UInt8])?

    var isFull: Bool { height >= Self.maximumHeight }

    func add(_ frame: CGImage) -> Outcome {
        let signature = Self.signature(of: frame)
        guard let (previousImage, previousSignature) = previous else {
            guard let copy = Self.copy(frame, rows: 0..<frame.height) else { return .unchanged }
            previous = (frame, signature)
            width = frame.width
            frameHeight = frame.height
            first = copy
            height = frame.height
            return .added(rows: frame.height)
        }
        guard frame.width == width, frame.height == previousImage.height, !isFull else { return .unchanged }
        let rows = frame.height
        let cols = Self.columns

        // Rows identical at the same position in both frames: sticky header (top) and footer (bottom).
        // Blank rows next to them can look still too, so these are upper bounds; the footer is
        // settled across all frames in result().
        func rowDifference(_ a: [UInt8], _ ai: Int, _ b: [UInt8], _ bi: Int) -> Int {
            var sum = 0
            for c in 0..<cols { sum += abs(Int(a[ai * cols + c]) - Int(b[bi * cols + c])) }
            return sum
        }
        let same = 2 * cols // up to 2 levels per column of noise
        var top = 0
        while top < rows && rowDifference(signature, top, previousSignature, top) <= same { top += 1 }
        if top == rows { return .unchanged }
        var bottom = 0
        while bottom < rows - top && rowDifference(signature, rows - 1 - bottom, previousSignature, rows - 1 - bottom) <= same { bottom += 1 }
        top = min(top, rows * 2 / 5)
        bottom = min(bottom, rows * 2 / 5)

        // Find how far the content moved up: frame row i shows what previous row i + shift showed.
        let bandStart = top, bandEnd = rows - bottom
        let band = bandEnd - bandStart
        guard band > 20 else { return .unchanged }
        let minimumOverlap = max(band / 6, 10)
        func score(_ shift: Int, step: Int) -> Double {
            var sum = 0, count = 0
            var i = bandStart
            while i + shift < bandEnd {
                sum += rowDifference(signature, i, previousSignature, i + shift)
                count += 1
                i += step
            }
            return count == 0 ? .infinity : Double(sum) / Double(count * cols)
        }
        // Coarse pass over every shift, then a fine pass around the best few.
        var candidates: [(shift: Int, score: Double)] = []
        for shift in 1...max(1, band - minimumOverlap) {
            candidates.append((shift, score(shift, step: 4)))
        }
        candidates.sort { $0.score < $1.score }
        var best = (shift: 0, score: Double.infinity)
        for candidate in candidates.prefix(4) {
            for shift in max(1, candidate.shift - 3)...min(band - minimumOverlap, candidate.shift + 3) where shift >= 1 {
                let s = score(shift, step: 1)
                if s < best.score { best = (shift, s) }
            }
        }
        // Something changed in place (a blinking cursor, a ticking clock) rather than scrolling:
        // the frame lines up with the last one about as well without any shift. Later frames are
        // compared with this one, so the change doesn't count against every frame after it.
        let unshifted = score(0, step: 1)
        if unshifted < 4, unshifted <= best.score * 2 + 0.5 {
            previous = (frame, signature)
            return .unchanged
        }
        // Average difference per sample must be small for a real match.
        guard best.shift > 0, best.score < 4 else { return .lost }

        let shift = min(best.shift, Self.maximumHeight - height)
        guard shift > 0, let piece = Self.copy(frame, rows: (rows - bottom - shift)..<rows) else { return .unchanged }
        pieces.append((piece, shift, bottom))
        height += shift
        previous = (frame, signature)
        return .added(rows: shift)
    }

    /// The joined image so far.
    func result() -> CGImage? {
        guard let first, width > 0 else { return nil }
        // The real footer is the smallest still region seen: anything more was blank content.
        let footer = pieces.map(\.footer).min() ?? 0
        var parts: [CGImage] = []
        if let top = first.cropping(to: CGRect(x: 0, y: 0, width: width, height: frameHeight - footer)) { parts.append(top) }
        for piece in pieces {
            // In the piece, the new rows start where its own (possibly overestimated) footer guess differs from the real one.
            let start = piece.footer - footer
            if let rows = piece.image.cropping(to: CGRect(x: 0, y: start, width: width, height: piece.shift)) { parts.append(rows) }
        }
        let last = pieces.last?.image ?? first
        if footer > 0, let bottom = last.cropping(to: CGRect(x: 0, y: last.height - footer, width: width, height: footer)) {
            parts.append(bottom)
        }
        let total = parts.reduce(0) { $0 + $1.height }
        guard total > 0, let context = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var y = total
        for part in parts {
            y -= part.height // Core Graphics draws from the bottom up
            context.draw(part, in: CGRect(x: 0, y: y, width: part.width, height: part.height))
        }
        return context.makeImage()
    }

    /// A standalone copy of some rows. A plain crop would keep the whole frame in memory.
    private static func copy(_ image: CGImage, rows: Range<Int>) -> CGImage? {
        guard !rows.isEmpty, let crop = image.cropping(to: CGRect(x: 0, y: rows.lowerBound, width: image.width, height: rows.count)),
              let context = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }

    /// Each row reduced to a few averaged gray values. Leaves out the side edges, where scroll bars
    /// appear and disappear.
    static func signature(of image: CGImage) -> [UInt8] {
        let rows = image.height
        let left = image.width * 2 / 100, right = image.width * 95 / 100
        guard let middle = image.cropping(to: CGRect(x: left, y: 0, width: max(right - left, 1), height: rows)) else {
            return [UInt8](repeating: 0, count: rows * columns)
        }
        var pixels = [UInt8](repeating: 0, count: rows * columns)
        pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: columns, height: rows, bitsPerComponent: 8,
                                          bytesPerRow: columns, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(middle, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }
        return pixels // row 0 is the top row: bitmap memory starts at the top
    }
}

/// Runs a scrolling capture: grabs the area repeatedly while you scroll, then hands on the joined image.
@MainActor
final class ScrollingCapture: ObservableObject {
    static let shared = ScrollingCapture()

    @Published private(set) var capturedHeight = 0
    @Published private(set) var lostTrack = false
    @Published private(set) var isFull = false
    private(set) var isActive = false

    private var stitcher = ScrollStitcher()
    private let queue = DispatchQueue(label: "dev.snapstash.scrolling", qos: .userInitiated)
    private var loop: Task<Void, Never>?
    private var controls: NSPanel?
    private var frame: NSPanel?
    private var scale: CGFloat = 2
    private var onFinish: ((Capture) -> Void)?

    func begin(_ selection: SelectionResult, content: SCShareableContent, onFinish: @escaping (Capture) -> Void) throws {
        let screen: NSScreen
        var area: CGRect // in the screen's points, bottom-left origin
        switch selection {
        case .cancelled:
            return
        case .area(let frozen, let rect):
            screen = frozen.screen
            area = rect
        case .screen(let frozen):
            screen = frozen.screen
            area = CGRect(origin: .zero, size: frozen.screen.frame.size)
        case .window(let target):
            // The window's visible part, as seen on screen (a scrolling window can't be captured on its own).
            guard let match = NSScreen.screens.max(by: {
                $0.frame.intersection(target.frame).width * $0.frame.intersection(target.frame).height
                    < $1.frame.intersection(target.frame).width * $1.frame.intersection(target.frame).height
            }) else { throw RecordingError.noDisplay }
            screen = match
            area = target.frame.intersection(match.frame).offsetBy(dx: -match.frame.minX, dy: -match.frame.minY)
        }
        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }), area.width >= 20, area.height >= 20 else {
            throw RecordingError.noDisplay
        }
        area = area.integral
        let filter = Self.filter(display: display, content: content)
        scale = screen.backingScaleFactor
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: area.minX, y: screen.frame.height - area.maxY, width: area.width, height: area.height)
        configuration.width = safeInt(area.width * scale)
        configuration.height = safeInt(area.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        stitcher = ScrollStitcher()
        capturedHeight = 0
        lostTrack = false
        isFull = false
        isActive = true
        self.onFinish = onFinish
        let global = area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        showFrame(global)
        showControls(near: global, on: screen)

        loop = Task { [weak self] in
            // The frame and controls opened just now, so the content fetched earlier may not list
            // them (or this app at all); fetch again so they're surely left out of the capture.
            var filter = filter
            if let fresh = try? await withTimeout(5, { try await SCShareableContent.current }) {
                filter = Self.filter(display: display, content: fresh)
            }
            var misses = 0
            while !Task.isCancelled {
                do {
                    let image = try await withTimeout(5) {
                        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                    }
                    guard let self, !Task.isCancelled else { return }
                    let stitcher = self.stitcher
                    let outcome = await withCheckedContinuation { continuation in
                        self.queue.async { continuation.resume(returning: stitcher.add(image)) }
                    }
                    let full = stitcher.isFull
                    let height = stitcher.height
                    switch outcome {
                    case .added: misses = 0
                    case .lost: misses += 1
                    case .unchanged: break
                    }
                    self.capturedHeight = height
                    self.lostTrack = misses >= 2
                    self.isFull = full
                } catch {
                    log.error("Scrolling capture frame failed: \(error.localizedDescription, privacy: .public)")
                    if CaptureError.isPermissionDenied(error) {
                        self?.cancel()
                        AppState.shared.permissionLost = true
                        MainWindow.shared.show()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
        }
    }

    /// The display without this app's own windows (the frame and controls drawn over the area).
    private static func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        let pid = ProcessInfo.processInfo.processIdentifier
        let own = content.applications.filter { $0.processID == pid }
        if !own.isEmpty {
            return SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        }
        let windows = content.windows.filter { $0.owningApplication?.processID == pid }
        return SCContentFilter(display: display, excludingWindows: windows)
    }

    func finish() {
        guard isActive else { return }
        stopLoop()
        let stitcher = self.stitcher
        let scale = self.scale
        let onFinish = self.onFinish
        self.onFinish = nil
        queue.async {
            let image = stitcher.result()
            DispatchQueue.main.async {
                guard let image else {
                    Toast.show("Nothing was captured", symbol: "exclamationmark.triangle.fill")
                    return
                }
                onFinish?(Capture(image: image, scale: scale))
            }
        }
    }

    func cancel() {
        guard isActive else { return }
        stopLoop()
        onFinish = nil
    }

    private func stopLoop() {
        isActive = false
        loop?.cancel()
        loop = nil
        for panel in [controls, frame].compactMap({ $0 }) {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        controls = nil
        frame = nil
    }

    // MARK: Panels

    private func showFrame(_ rect: CGRect) {
        let panel = NSPanel(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true // scrolling goes straight through to the app underneath
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: Rectangle()
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        panel.orderFrontRegardless()
        frame = panel
    }

    private func showControls(near rect: CGRect, on screen: NSScreen) {
        let size = NSSize(width: 330, height: 46)
        let visible = screen.visibleFrame
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < visible.minY { origin.y = rect.maxY + 10 }
        if origin.y + size.height > visible.maxY { origin.y = rect.minY + 10 } // inside the area if there's no room; it's excluded from the capture
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: ScrollingControls(capture: self))
        panel.orderFrontRegardless()
        controls = panel
    }
}

private struct ScrollingControls: View {
    @ObservedObject var capture: ScrollingCapture

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: capture.lostTrack ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(capture.lostTrack ? .orange : .white)
            VStack(alignment: .leading, spacing: 0) {
                Text(status).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("\(capture.capturedHeight.formatted()) px").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
            }
            Spacer(minLength: 0)
            Button("Cancel") { capture.cancel() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Button { capture.finish() } label: {
                Text("Done")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .help("Finish (\(Prefs.shortcut(for: .scrolling)?.display ?? "menu bar"))")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black.opacity(0.82)))
    }

    private var status: String {
        if capture.isFull { return "Maximum length reached" }
        if capture.lostTrack { return "Scroll more slowly" }
        return capture.capturedHeight == 0 ? "Starting…" : "Scroll down slowly"
    }
}
