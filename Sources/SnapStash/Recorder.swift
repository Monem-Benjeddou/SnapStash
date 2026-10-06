import AVFoundation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

enum RecordingFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    var id: String { rawValue }
}

enum RecordingError: LocalizedError {
    case noDisplay
    case writerFailed(String)
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "The display to record isn't available."
        case .writerFailed(let reason): return "The video couldn't be written: \(reason)"
        case .nothingRecorded: return "Nothing was recorded."
        }
    }
}

/// One recording: a ScreenCaptureKit stream written to an MP4 file. Sample buffers arrive on
/// `queue`, and the writer is only ever touched there.
final class RecordingSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let url: URL
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "dev.snapstash.recording", qos: .userInitiated)
    private var sessionStarted = false
    private var lastVideoBuffer: CMSampleBuffer?
    private var stopped = false
    private var stopRequestedAt: CMTime?
    /// Called on the main thread if the stream stops by itself (display unplugged, permission revoked).
    var onUnexpectedStop: ((Error) -> Void)?

    init(filter: SCContentFilter, configuration: SCStreamConfiguration, fps: Int, url: URL) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = configuration.width, height = configuration.height
        // Screen content compresses well; this keeps text sharp without huge files.
        let bitrate = min(max(width * height * fps / 6, 2_000_000), 40_000_000)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.writerFailed("unsupported video size") }
        writer.add(videoInput)

        if configuration.capturesAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ])
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) { writer.add(input); audioInput = input } else { audioInput = nil }
        } else {
            audioInput = nil
        }
        super.init()

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if audioInput != nil { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        self.stream = stream
    }

    func start() async throws {
        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error")
        }
        try await withTimeout(8) { [stream] in try await stream?.startCapture() }
    }

    /// Stops capturing and finishes the file. The last frame is held until the moment you stopped,
    /// so a recording that ends on a still screen keeps its full length.
    func stop() async throws -> URL {
        // The video ends when you pressed Stop, not when the stream has finished shutting down.
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        queue.sync { stopRequestedAt = stopTime }
        try? await withTimeout(5) { [stream] in try await stream?.stopCapture() }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                stopped = true
                guard sessionStarted else {
                    writer.cancelWriting()
                    continuation.resume(throwing: RecordingError.nothingRecorded)
                    return
                }
                let now = stopTime
                if let last = lastVideoBuffer, videoInput.isReadyForMoreMediaData {
                    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
                    var copy: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                             sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                       let copy, CMTimeCompare(now, CMSampleBufferGetPresentationTimeStamp(last)) > 0 {
                        videoInput.append(copy)
                    }
                }
                lastVideoBuffer = nil
                writer.endSession(atSourceTime: now)
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: RecordingError.writerFailed(writer.error?.localizedDescription ?? "unknown error"))
                    }
                }
            }
        }
    }

    // MARK: SCStreamOutput (on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !stopped, writer.status == .writing, sampleBuffer.isValid else { return }
        // Anything stamped after Stop was pressed is left out.
        if let stopRequestedAt, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), stopRequestedAt) > 0 { return }
        switch type {
        case .screen:
            // Frames where nothing changed carry no image; only complete frames are written.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: rawStatus) == .complete else { return }
            if !sessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                sessionStarted = true
            }
            if videoInput.isReadyForMoreMediaData { videoInput.append(sampleBuffer) }
            lastVideoBuffer = sampleBuffer
        case .audio:
            guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        default:
            break
        }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.error("Recording stream stopped: \(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async { [self] in onUnexpectedStop?(error) }
    }
}

/// Starts and stops recordings, shows the recording controls, and hands the finished file on.
@MainActor
final class ScreenRecorder {
    static let shared = ScreenRecorder()

    private var session: RecordingSession?
    private var controls: NSPanel?
    private var areaFrame: NSPanel?
    private var isStopping = false

    var isRecording: Bool { session != nil }

    /// Starts recording what was picked in the selection overlay.
    func begin(_ selection: SelectionResult, content: SCShareableContent) async throws {
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        var sourceRect: CGRect?
        var pixelSize: CGSize
        var screen: NSScreen?
        var areaOnScreen: CGRect?

        switch selection {
        case .cancelled:
            return
        case .screen(let frozen), .area(let frozen, _):
            guard let display = content.displays.first(where: { $0.displayID == frozen.screen.displayID }) else {
                throw RecordingError.noDisplay
            }
            // SnapStash's own windows (the recording controls) are left out of the video.
            filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            screen = frozen.screen
            pixelSize = CGSize(width: frozen.screen.frame.width * frozen.scale, height: frozen.screen.frame.height * frozen.scale)
            if case .area(_, let rect) = selection {
                // ScreenCaptureKit wants the area in the display's points with a top-left origin.
                sourceRect = CGRect(x: rect.minX, y: frozen.screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                pixelSize = CGSize(width: rect.width * frozen.scale, height: rect.height * frozen.scale)
                areaOnScreen = rect.offsetBy(dx: frozen.screen.frame.minX, dy: frozen.screen.frame.minY)
            }
        case .window(let target):
            filter = SCContentFilter(desktopIndependentWindow: target.window)
            let scale = CGFloat(filter.pointPixelScale)
            pixelSize = CGSize(width: filter.contentRect.width * scale, height: filter.contentRect.height * scale)
            screen = NSScreen.screens.first { $0.frame.intersects(target.frame) }
            areaOnScreen = target.frame
        }

        let fps = Prefs.recordingFPS
        let size = Self.encodableSize(pixelSize)
        let configuration = SCStreamConfiguration()
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        if let sourceRect { configuration.sourceRect = sourceRect }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        configuration.showsCursor = Prefs.recordCursor
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 8
        configuration.capturesAudio = Prefs.recordAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SnapStash Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(Self.fileName(extension: "mp4"))
        try? FileManager.default.removeItem(at: url)

        let session = try RecordingSession(filter: filter, configuration: configuration, fps: fps, url: url)
        session.onUnexpectedStop = { [weak self] error in
            guard let self, self.session === session else { return }
            if CaptureError.isPermissionDenied(error) {
                AppState.shared.permissionLost = true
            }
            Toast.show("Recording stopped: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            self.stop()
        }
        try await session.start()
        self.session = session
        AppState.shared.recordingStartedAt = Date()
        showControls(on: screen ?? NSScreen.underMouse, avoiding: areaOnScreen)
        if let areaOnScreen, case .area = selection { showAreaFrame(areaOnScreen) }
        log.notice("Recording started: \(Int(size.width))x\(Int(size.height)) at \(fps) fps")
    }

    /// Stops the recording and saves it (as MP4, or converted to GIF).
    func stop() {
        guard let session, !isStopping else { return }
        isStopping = true
        hideControls()
        Task {
            defer {
                self.session = nil
                self.isStopping = false
                AppState.shared.recordingStartedAt = nil
            }
            do {
                let temporary = try await session.stop()
                var saved = try Self.moveIntoCaptures(temporary)
                if Prefs.recordingFormat == .gif {
                    Toast.show("Making GIF…", symbol: "hourglass")
                    let gif = saved.deletingPathExtension().appendingPathExtension("gif")
                    do {
                        try await GIFExporter.export(saved, to: gif)
                        try? FileManager.default.removeItem(at: saved)
                        saved = gif
                    } catch {
                        // The MP4 is kept, so nothing is lost.
                        log.error("GIF export failed: \(error.localizedDescription, privacy: .public)")
                        Toast.show("Couldn't make a GIF, so the recording was saved as MP4",
                                   symbol: "exclamationmark.triangle.fill")
                    }
                }
                QuickAccess.shared.showRecording(saved)
                CaptureLibrary.shared.reload()
            } catch RecordingError.nothingRecorded {
                Toast.show("Nothing was recorded", symbol: "exclamationmark.triangle.fill")
            } catch {
                log.error("Recording failed: \(error.localizedDescription, privacy: .public)")
                Toast.show("Recording failed: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: Files

    static func fileName(extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "SnapStash Recording \(formatter.string(from: Date())).\(ext)"
    }

    /// Moves a finished recording into the capture folder (or the default one if that's unavailable).
    private static func moveIntoCaptures(_ url: URL) throws -> URL {
        for folder in [Prefs.folder, Prefs.defaultFolder] {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var destination = folder.appendingPathComponent(url.lastPathComponent)
                var counter = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    destination = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) \(counter).\(url.pathExtension)")
                    counter += 1
                }
                try FileManager.default.moveItem(at: url, to: destination)
                if folder != Prefs.folder {
                    Toast.show("“\(Prefs.folder.lastPathComponent)” isn't available, so this was saved to Pictures › SnapStash",
                               symbol: "exclamationmark.triangle.fill")
                }
                return destination
            } catch {
                log.error("Couldn't save the recording to \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        throw CocoaError(.fileWriteUnknown)
    }

    /// H.264 has size limits: fit within 4K UHD, and keep both sides even.
    static func encodableSize(_ size: CGSize) -> CGSize {
        let factor = min(1, 3840 / max(size.width, 1), 2160 / max(size.height, 1))
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * factor / 2).rounded(.down) * 2) }
        return CGSize(width: even(size.width), height: even(size.height))
    }

    // MARK: Controls

    private func showControls(on screen: NSScreen?, avoiding area: CGRect?) {
        guard let screen else { return }
        let size = NSSize(width: 168, height: 40)
        var origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 12)
        // Out of the recorded area where possible (it's left out of the video either way).
        if let area, area.intersects(NSRect(origin: origin, size: size)), area.minY - size.height - 12 > screen.visibleFrame.minY {
            origin.y = area.minY - size.height - 12
        }
        let panel = NSPanel(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: RecordingControls { ScreenRecorder.shared.stop() })
        panel.orderFrontRegardless()
        controls = panel
    }

    /// A dashed outline around the recorded area, so you can see what's being recorded.
    private func showAreaFrame(_ rect: CGRect) {
        let outset = rect.insetBy(dx: -3, dy: -3)
        let panel = NSPanel(contentRect: outset, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: Rectangle()
            .strokeBorder(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
        panel.orderFrontRegardless()
        areaFrame = panel
    }

    private func hideControls() {
        for panel in [controls, areaFrame].compactMap({ $0 }) {
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        controls = nil
        areaFrame = nil
    }
}

private struct RecordingControls: View {
    let stop: () -> Void
    @ObservedObject private var state = AppState.shared

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(.red).frame(width: 9, height: 9)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(elapsed(at: context.date))
                    .font(.system(.body, design: .rounded).monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            }
            Spacer(minLength: 0)
            Button(action: stop) {
                Text("Stop")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            .help("Stop recording (\(Prefs.shortcut(for: .record)?.display ?? "menu bar"))")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(.black.opacity(0.82)))
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(state.recordingStartedAt ?? date)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// Turns a video into an animated GIF, sized for sharing.
enum GIFExporter {
    static func export(_ video: URL, to gif: URL, maxSide: CGFloat = 960, fps: Double = 12) async throws {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw RecordingError.nothingRecorded }
        // Long recordings get fewer frames per second, so the GIF stays a reasonable size.
        let rate = min(fps, 1200 / duration)
        let count = max(1, Int(duration * rate))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        generator.appliesPreferredTrackTransform = true
        let tolerance = CMTime(value: 1, timescale: 30)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        try? FileManager.default.removeItem(at: gif)
        guard let destination = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / rate],
        ] as CFDictionary
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / rate, preferredTimescale: 600)
            let (image, _) = try await generator.image(at: time)
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
