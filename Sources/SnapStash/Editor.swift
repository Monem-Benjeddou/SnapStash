import AppKit
import SwiftUI

// MARK: - Model

enum EditorTool: String, CaseIterable, Identifiable {
    case select, arrow, box, text, highlighter, step, blur, crop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .box: return "Box"
        case .text: return "Text"
        case .highlighter: return "Highlighter"
        case .step: return "Numbered Step"
        case .blur: return "Blur"
        case .crop: return "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .box: return "square"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .step: return "1.circle"
        case .blur: return "checkerboard.rectangle"
        case .crop: return "crop"
        }
    }

    /// One-key shortcut, shown in the tooltip.
    var key: Character {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .box: return "r"
        case .text: return "t"
        case .highlighter: return "h"
        case .step: return "n"
        case .blur: return "b"
        case .crop: return "c"
        }
    }
}

/// One mark on the image. Positions are in image pixels with a top-left origin.
struct Annotation: Identifiable, Equatable {
    enum Shape: Equatable {
        case arrow(CGPoint, CGPoint)
        case box(CGRect)
        case text(CGPoint, String)
        case highlight([CGPoint])
        case step(CGPoint)
        case blur(CGRect)
    }

    var id = UUID()
    var shape: Shape
    var color: NSColor
    /// Line width in image pixels; text, steps and highlighter strokes scale from it.
    var size: CGFloat

    func offset(by delta: CGVector) -> Annotation {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + delta.dx, y: p.y + delta.dy) }
        var copy = self
        switch shape {
        case .arrow(let a, let b): copy.shape = .arrow(move(a), move(b))
        case .box(let r): copy.shape = .box(r.offsetBy(dx: delta.dx, dy: delta.dy))
        case .text(let p, let s): copy.shape = .text(move(p), s)
        case .highlight(let points): copy.shape = .highlight(points.map(move))
        case .step(let p): copy.shape = .step(move(p))
        case .blur(let r): copy.shape = .blur(r.offsetBy(dx: delta.dx, dy: delta.dy))
        }
        return copy
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let base: CGImage
    /// Pixels per point of the capture (2 on Retina), so sizes look the same on any screen.
    let scale: CGFloat
    let name: String

    @Published var annotations: [Annotation] = []
    @Published var crop: CGRect?
    @Published var pendingCrop: CGRect?
    @Published var selectedID: UUID?
    @Published private(set) var hasChanges = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    @Published var tool: EditorTool = .arrow {
        didSet {
            if tool != .select { selectedID = nil }
            pendingCrop = tool == .crop ? (crop ?? fullRect) : nil
        }
    }
    @Published var color: NSColor = EditorModel.palette[0] {
        didSet { updateSelected { $0.color = color } }
    }
    @Published var sizeIndex = 1 {
        didSet { updateSelected { $0.size = strokeWidth } }
    }

    static let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .black, .white]

    private struct Snapshot { let annotations: [Annotation]; let crop: CGRect? }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var pixelateCache: [String: CGImage] = [:]

    init(image: CGImage, scale: CGFloat, name: String) {
        base = image
        self.scale = max(scale, 1)
        self.name = name
    }

    var fullRect: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    /// What the canvas shows: the whole image while cropping, otherwise the cropped part.
    var viewport: CGRect { tool == .crop ? fullRect : (crop ?? fullRect) }
    var strokeWidth: CGFloat { [3, 5, 8][min(max(sizeIndex, 0), 2)] * scale }
    var selected: Annotation? { annotations.first { $0.id == selectedID } }

    // MARK: Undo

    /// Call before every change, so it can be undone.
    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        hasChanges = true
        refreshUndoState()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(last)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        annotations = snapshot.annotations
        crop = snapshot.crop
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        hasChanges = true
        refreshUndoState()
    }

    private func refreshUndoState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func markSaved() { hasChanges = false }

    /// Takes back the annotation just added, leaving no trace in undo or redo (a click that didn't drag).
    func discardLastAdd() {
        guard let last = undoStack.popLast() else { return }
        annotations = last.annotations
        crop = last.crop
        selectedID = nil
        refreshUndoState()
    }

    // MARK: Editing

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
        selectedID = annotation.id
    }

    func replace(_ annotation: Annotation) {
        guard let index = annotations.firstIndex(where: { $0.id == annotation.id }) else { return }
        annotations[index] = annotation
    }

    func deleteSelected() {
        guard let selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == selectedID }
        self.selectedID = nil
    }

    private func updateSelected(_ change: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == selectedID }) else { return }
        var copy = annotations[index]
        change(&copy)
        guard copy != annotations[index] else { return }
        checkpoint()
        annotations[index] = copy
    }

    func applyCrop() {
        guard let pending = pendingCrop?.integral.intersection(fullRect), pending.width >= 4, pending.height >= 4 else { return }
        checkpoint()
        crop = pending == fullRect ? nil : pending
        tool = .select
    }

    func cancelCrop() { tool = .select }

    /// The number shown in a step: its position among the steps, so deleting one renumbers the rest.
    func stepNumber(of annotation: Annotation) -> Int {
        var number = 0
        for item in annotations {
            if case .step = item.shape { number += 1 }
            if item.id == annotation.id { return number }
        }
        return number
    }

    /// A blocky copy of a region of the original. Pixelation, unlike a soft blur, can't be undone
    /// to recover text.
    func pixelated(_ rect: CGRect) -> CGImage? {
        let region = rect.standardized.integral.intersection(fullRect)
        guard region.width >= 2, region.height >= 2 else { return nil }
        let key = "\(region)"
        if let cached = pixelateCache[key] { return cached }
        guard let source = base.cropping(to: region) else { return nil }
        let block = max(6 * scale, min(region.width, region.height) / 14)
        let width = max(1, Int(region.width / block)), height = max(1, Int(region.height / block))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return nil }
        if pixelateCache.count > 64 { pixelateCache.removeAll() }
        pixelateCache[key] = small
        return small
    }

    // MARK: Output

    /// The finished image at full resolution: annotations drawn in, crop applied.
    func render() -> CGImage? {
        let width = base.width, height = base.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1) // top-left origin, like the annotations
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        AnnotationRenderer.drawImage(base, in: fullRect, context: context)
        AnnotationRenderer.draw(annotations, model: self, context: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if let crop { return image.cropping(to: crop.integral) }
        return image
    }

    func renderedCapture() -> Capture? {
        render().map { Capture(image: $0, scale: scale) }
    }
}

// MARK: - Drawing

/// Draws annotations into a context whose coordinates are image pixels with a top-left origin.
@MainActor
enum AnnotationRenderer {
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: rect)
        context.restoreGState()
    }

    static func draw(_ annotations: [Annotation], model: EditorModel, context: CGContext) {
        for annotation in annotations { draw(annotation, model: model, context: context) }
    }

    static func draw(_ annotation: Annotation, model: EditorModel, context: CGContext) {
        let size = annotation.size
        let color = annotation.color.cgColor
        context.saveGState()
        defer { context.restoreGState() }
        switch annotation.shape {
        case .arrow(let from, let to):
            context.setShadow(offset: .zero, blur: size * 1.2, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            let path = arrowPath(from: from, to: to, width: size)
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        case .box(let rect):
            context.setShadow(offset: .zero, blur: size * 1.2, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            let r = rect.standardized
            context.addPath(CGPath(roundedRect: r, cornerWidth: min(size * 1.5, r.width / 2), cornerHeight: min(size * 1.5, r.height / 2), transform: nil))
            context.setStrokeColor(color)
            context.setLineWidth(size)
            context.strokePath()
        case .text(let origin, let string):
            textString(string, annotation: annotation).draw(at: origin)
        case .highlight(let points):
            guard let first = points.first else { return }
            context.setBlendMode(.multiply)
            context.setStrokeColor(annotation.color.withAlphaComponent(0.4).cgColor)
            context.setLineWidth(highlighterWidth(size))
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.move(to: first)
            for point in points.dropFirst() { context.addLine(to: point) }
            if points.count == 1 { context.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            context.strokePath()
        case .step(let center):
            let radius = stepRadius(size)
            context.setShadow(offset: CGSize(width: 0, height: size * 0.3), blur: size * 1.2,
                              color: NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(max(size * 0.4, 1))
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            let label = NSAttributedString(string: "\(model.stepNumber(of: annotation))", attributes: [
                .font: NSFont.systemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: contrastingColor(for: annotation.color),
            ])
            let labelSize = label.size()
            label.draw(at: CGPoint(x: center.x - labelSize.width / 2, y: center.y - labelSize.height / 2))
        case .blur(let rect):
            let r = rect.standardized.integral.intersection(model.fullRect)
            guard let patch = model.pixelated(r) else { return }
            context.interpolationQuality = .none
            drawImage(patch, in: r, context: context)
        }
    }

    static func highlighterWidth(_ size: CGFloat) -> CGFloat { size * 4.5 }
    static func stepRadius(_ size: CGFloat) -> CGFloat { size * 3 }
    static func fontSize(_ size: CGFloat) -> CGFloat { size * 4.5 }

    static func textString(_ string: String, annotation: Annotation) -> NSAttributedString {
        // A soft glow in the opposite tone keeps text readable on any background.
        let glow = NSShadow()
        glow.shadowColor = contrastingColor(for: annotation.color).withAlphaComponent(0.9)
        glow.shadowBlurRadius = annotation.size * 0.8
        glow.shadowOffset = .zero
        return NSAttributedString(string: string.isEmpty ? " " : string, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize(annotation.size), weight: .bold),
            .foregroundColor: annotation.color,
            .shadow: glow,
        ])
    }

    static func contrastingColor(for color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.6 ? .black : .white
    }

    /// A tapered arrow: thin at the tail, with a solid head.
    static func arrowPath(from: CGPoint, to: CGPoint, width: CGFloat) -> CGPath {
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(hypot(dx, dy), 0.001)
        let ux = dx / length, uy = dy / length
        let px = -uy, py = ux
        let headLength = min(max(width * 4.5, 12), length * 0.6)
        let headWidth = headLength * 0.62
        let shaft = width * 0.5
        let tail = width * 0.15
        let neck = CGPoint(x: to.x - ux * headLength, y: to.y - uy * headLength)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: from.x + px * tail, y: from.y + py * tail))
        path.addLine(to: CGPoint(x: neck.x + px * shaft, y: neck.y + py * shaft))
        path.addLine(to: CGPoint(x: neck.x + px * headWidth, y: neck.y + py * headWidth))
        path.addLine(to: to)
        path.addLine(to: CGPoint(x: neck.x - px * headWidth, y: neck.y - py * headWidth))
        path.addLine(to: CGPoint(x: neck.x - px * shaft, y: neck.y - py * shaft))
        path.addLine(to: CGPoint(x: from.x - px * tail, y: from.y - py * tail))
        path.closeSubpath()
        return path
    }

    /// The area an annotation covers, for selection outlines and hit testing.
    static func bounds(of annotation: Annotation, model: EditorModel) -> CGRect {
        let size = annotation.size
        switch annotation.shape {
        case .arrow(let a, let b):
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).insetBy(dx: -size * 3, dy: -size * 3)
        case .box(let r): return r.standardized.insetBy(dx: -size / 2, dy: -size / 2)
        case .text(let p, let s): return CGRect(origin: p, size: textString(s, annotation: annotation).size())
        case .highlight(let points):
            let xs = points.map(\.x), ys = points.map(\.y)
            let half = highlighterWidth(size) / 2
            return CGRect(x: (xs.min() ?? 0) - half, y: (ys.min() ?? 0) - half,
                          width: (xs.max() ?? 0) - (xs.min() ?? 0) + half * 2, height: (ys.max() ?? 0) - (ys.min() ?? 0) + half * 2)
        case .step(let c):
            let r = stepRadius(size)
            return CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        case .blur(let r): return r.standardized
        }
    }

    static func hitTest(_ annotation: Annotation, at point: CGPoint, tolerance: CGFloat, model: EditorModel) -> Bool {
        func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
            let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
            return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
        }
        switch annotation.shape {
        case .arrow(let a, let b): return distance(point, a, b) <= tolerance + annotation.size * 2
        case .highlight(let points):
            guard points.count > 1 else { return points.first.map { hypot(point.x - $0.x, point.y - $0.y) <= tolerance + highlighterWidth(annotation.size) / 2 } ?? false }
            return zip(points, points.dropFirst()).contains { distance(point, $0, $1) <= tolerance + highlighterWidth(annotation.size) / 2 }
        default:
            return bounds(of: annotation, model: model).insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }
}

// MARK: - Canvas

/// Shows the image and annotations, and turns mouse input into edits.
final class EditorCanvas: NSView, NSTextFieldDelegate {
    var model: EditorModel!

    private enum Handle: Equatable { case start, end, corner(Int) }
    private enum Drag {
        case drawing(UUID)
        case moving(UUID, last: CGPoint, moved: Bool)
        case resizing(UUID, Handle)
        case cropping(start: CGPoint)
    }

    private var drag: Drag?
    private var factor: CGFloat = 1
    private var origin: CGPoint = .zero
    private var textField: NSTextField?
    /// The text annotation being edited (removed from the image while its field is open).
    private var editingText: Annotation?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    private func updateTransform() {
        let viewport = model.viewport
        let available = bounds.insetBy(dx: 28, dy: 28)
        factor = max(0.01, min(available.width / viewport.width, available.height / viewport.height, 2 / model.scale))
        origin = CGPoint(x: bounds.midX - viewport.width * factor / 2, y: bounds.midY - viewport.height * factor / 2)
    }

    private func toImage(_ point: CGPoint) -> CGPoint {
        let viewport = model.viewport
        return CGPoint(x: (point.x - origin.x) / factor + viewport.minX, y: (point.y - origin.y) / factor + viewport.minY)
    }

    private func toView(_ point: CGPoint) -> CGPoint {
        let viewport = model.viewport
        return CGPoint(x: (point.x - viewport.minX) * factor + origin.x, y: (point.y - viewport.minY) * factor + origin.y)
    }

    private func toView(_ rect: CGRect) -> CGRect {
        let a = toView(rect.origin)
        return CGRect(x: a.x, y: a.y, width: rect.width * factor, height: rect.height * factor)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let full = model.fullRect
        return CGPoint(x: min(max(point.x, full.minX), full.maxX), y: min(max(point.y, full.minY), full.maxY))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let model, let context = NSGraphicsContext.current?.cgContext else { return }
        updateTransform()
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let imageFrame = toView(model.viewport)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 4), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        NSColor.windowBackgroundColor.setFill()
        imageFrame.fill()
        context.restoreGState()

        context.saveGState()
        context.clip(to: imageFrame)
        context.translateBy(x: origin.x, y: origin.y)
        context.scaleBy(x: factor, y: factor)
        context.translateBy(x: -model.viewport.minX, y: -model.viewport.minY)
        context.interpolationQuality = factor < 1 ? .high : .none
        AnnotationRenderer.drawImage(model.base, in: model.fullRect, context: context)
        context.interpolationQuality = .high
        AnnotationRenderer.draw(model.annotations, model: model, context: context)
        context.restoreGState()

        if model.tool == .crop { drawCropOverlay(imageFrame: imageFrame) }
        drawSelection()
    }

    private func drawSelection() {
        guard model.tool == .select || drag == nil, let selected = model.selected else { return }
        let frame = toView(AnnotationRenderer.bounds(of: selected, model: model)).insetBy(dx: -4, dy: -4)
        let outline = NSBezierPath(rect: frame)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
        for (_, point) in handles(for: selected) {
            let p = toView(point)
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func drawCropOverlay(imageFrame: CGRect) {
        guard let pending = model.pendingCrop else { return }
        let rect = toView(pending.standardized)
        let dim = NSBezierPath(rect: imageFrame)
        dim.append(NSBezierPath(rect: rect))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let thirds = NSBezierPath()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3, y = rect.minY + rect.height * CGFloat(i) / 3
            thirds.move(to: NSPoint(x: x, y: rect.minY)); thirds.line(to: NSPoint(x: x, y: rect.maxY))
            thirds.move(to: NSPoint(x: rect.minX, y: y)); thirds.line(to: NSPoint(x: rect.maxX, y: y))
        }
        thirds.lineWidth = 0.5
        thirds.stroke()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = 1.5
        border.stroke()
        let label = "\(Int(pending.standardized.width)) × \(Int(pending.standardized.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                         .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        let box = NSRect(x: rect.minX, y: max(rect.minY - size.height - 10, imageFrame.minY), width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: box.minX + 5, y: box.minY + 2), withAttributes: attributes)
    }

    // MARK: Handles

    private func handles(for annotation: Annotation) -> [(Handle, CGPoint)] {
        switch annotation.shape {
        case .arrow(let a, let b): return [(.start, a), (.end, b)]
        case .box(let r), .blur(let r):
            let s = r.standardized
            return [(.corner(0), CGPoint(x: s.minX, y: s.minY)), (.corner(1), CGPoint(x: s.maxX, y: s.minY)),
                    (.corner(2), CGPoint(x: s.maxX, y: s.maxY)), (.corner(3), CGPoint(x: s.minX, y: s.maxY))]
        default: return []
        }
    }

    private func applying(_ handle: Handle, to point: CGPoint, on annotation: Annotation) -> Annotation {
        var copy = annotation
        switch (annotation.shape, handle) {
        case (.arrow(_, let b), .start): copy.shape = .arrow(point, b)
        case (.arrow(let a, _), .end): copy.shape = .arrow(a, point)
        case (.box(let r), .corner(let i)): copy.shape = .box(rectByMovingCorner(i, of: r, to: point))
        case (.blur(let r), .corner(let i)): copy.shape = .blur(rectByMovingCorner(i, of: r, to: point))
        default: break
        }
        return copy
    }

    private func rectByMovingCorner(_ index: Int, of rect: CGRect, to point: CGPoint) -> CGRect {
        let s = rect.standardized
        let corners = [CGPoint(x: s.minX, y: s.minY), CGPoint(x: s.maxX, y: s.minY), CGPoint(x: s.maxX, y: s.maxY), CGPoint(x: s.minX, y: s.maxY)]
        let opposite = corners[(index + 2) % 4]
        return CGRect(x: min(opposite.x, point.x), y: min(opposite.y, point.y), width: abs(point.x - opposite.x), height: abs(point.y - opposite.y))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        commitText()
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let point = clamped(toImage(viewPoint))
        let tolerance = 6 / factor

        // A handle of the selected annotation wins, whatever the tool.
        if let selected = model.selected,
           let handle = handles(for: selected).first(where: { hypot(toView($0.1).x - viewPoint.x, toView($0.1).y - viewPoint.y) <= 8 })?.0 {
            model.checkpoint()
            drag = .resizing(selected.id, handle)
            return
        }

        switch model.tool {
        case .select:
            if let hit = model.annotations.last(where: { AnnotationRenderer.hitTest($0, at: point, tolerance: tolerance, model: model) }) {
                model.selectedID = hit.id
                if event.clickCount == 2, case .text = hit.shape {
                    beginEditing(hit)
                    return
                }
                drag = .moving(hit.id, last: point, moved: false)
            } else {
                model.selectedID = nil
            }
        case .text:
            if let hit = model.annotations.last(where: {
                if case .text = $0.shape { return AnnotationRenderer.hitTest($0, at: point, tolerance: tolerance, model: model) }
                return false
            }) {
                beginEditing(hit)
            } else {
                beginEditing(Annotation(shape: .text(point, ""), color: model.color, size: model.strokeWidth), isNew: true)
            }
        case .step:
            model.add(Annotation(shape: .step(point), color: model.color, size: model.strokeWidth))
        case .crop:
            drag = .cropping(start: point)
            model.pendingCrop = CGRect(origin: point, size: .zero)
        case .arrow, .box, .highlighter, .blur:
            let shape: Annotation.Shape
            switch model.tool {
            case .arrow: shape = .arrow(point, point)
            case .box: shape = .box(CGRect(origin: point, size: .zero))
            case .highlighter: shape = .highlight([point])
            default: shape = .blur(CGRect(origin: point, size: .zero))
            }
            let annotation = Annotation(shape: shape, color: model.color, size: model.strokeWidth)
            model.add(annotation)
            drag = .drawing(annotation.id)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var point = clamped(toImage(convert(event.locationInWindow, from: nil)))
        let shift = event.modifierFlags.contains(.shift)
        switch drag {
        case .drawing(let id):
            guard var annotation = model.annotations.first(where: { $0.id == id }) else { return }
            switch annotation.shape {
            case .arrow(let a, _):
                if shift { point = snapped(point, from: a) }
                annotation.shape = .arrow(a, point)
            case .box(let r): annotation.shape = .box(dragRect(from: r.origin, to: point, square: shift))
            case .blur(let r): annotation.shape = .blur(dragRect(from: r.origin, to: point, square: shift))
            case .highlight(var points):
                if shift, let first = points.first { points = [first, snapped(point, from: first)] } else { points.append(point) }
                annotation.shape = .highlight(points)
            default: break
            }
            model.replace(annotation)
        case .moving(let id, let last, let moved):
            guard let annotation = model.annotations.first(where: { $0.id == id }) else { return }
            if !moved { model.checkpoint() }
            model.replace(annotation.offset(by: CGVector(dx: point.x - last.x, dy: point.y - last.y)))
            drag = .moving(id, last: point, moved: true)
        case .resizing(let id, let handle):
            guard let annotation = model.annotations.first(where: { $0.id == id }) else { return }
            model.replace(applying(handle, to: point, on: annotation))
        case .cropping(let start):
            model.pendingCrop = dragRect(from: start, to: point, square: shift)
        case nil:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        guard case .drawing(let id) = drag, let annotation = model.annotations.first(where: { $0.id == id }) else { return }
        // A click without a drag leaves nothing behind (except a highlighter dot).
        let bounds = AnnotationRenderer.bounds(of: annotation, model: model)
        let tiny: Bool
        switch annotation.shape {
        case .arrow(let a, let b): tiny = hypot(a.x - b.x, a.y - b.y) < 4 * model.scale
        case .box(let r), .blur(let r): tiny = r.width < 3 * model.scale || r.height < 3 * model.scale
        default: tiny = bounds.isEmpty
        }
        if tiny { model.discardLastAdd() }
    }

    override func rightMouseDown(with event: NSEvent) {
        if model.tool == .crop { model.cancelCrop() } else { model.selectedID = nil }
        needsDisplay = true
    }

    private func dragRect(from start: CGPoint, to point: CGPoint, square: Bool) -> CGRect {
        var width = point.x - start.x, height = point.y - start.y
        if square {
            let side = max(abs(width), abs(height))
            width = width < 0 ? -side : side
            height = height < 0 ? -side : side
        }
        return CGRect(x: start.x, y: start.y, width: width, height: height).standardized
    }

    /// Holding Shift snaps to 45° steps.
    private func snapped(_ point: CGPoint, from origin: CGPoint) -> CGPoint {
        let dx = point.x - origin.x, dy = point.y - origin.y
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let length = hypot(dx, dy)
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 51, 117: // delete
            model.deleteSelected()
        case 53: // esc
            if model.tool == .crop { model.cancelCrop() } else { model.selectedID = nil }
        case 36, 76: // return
            if model.tool == .crop { model.applyCrop() }
        case 123, 124, 125, 126: // arrows nudge the selection
            guard let selected = model.selected else { return }
            let step = (event.modifierFlags.contains(.shift) ? 10 : 1) * model.scale
            let delta: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                                   125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][Int(event.keyCode)]!
            model.checkpoint()
            model.replace(selected.offset(by: delta))
        default:
            let modifiers = event.modifierFlags.intersection([.command, .control, .option])
            if modifiers.isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = EditorTool.allCases.first(where: { $0.key == character }) {
                model.tool = tool
            } else if modifiers.isEmpty, let character = event.charactersIgnoringModifiers?.first,
                      let digit = Int(String(character)), (1...EditorModel.palette.count).contains(digit) {
                model.color = EditorModel.palette[digit - 1]
            } else {
                super.keyDown(with: event)
            }
        }
        needsDisplay = true
    }

    // MARK: Text

    private func beginEditing(_ annotation: Annotation, isNew: Bool = false) {
        guard case .text(let position, let string) = annotation.shape else { return }
        if !isNew {
            model.checkpoint()
            model.annotations.removeAll { $0.id == annotation.id }
        }
        editingText = annotation
        let field = NSTextField(string: string)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: AnnotationRenderer.fontSize(annotation.size) * factor, weight: .bold)
        field.textColor = annotation.color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "Type here"
        let start = toView(position)
        field.frame = NSRect(x: start.x - 2, y: start.y, width: 200, height: (field.font?.pointSize ?? 20) * 1.4)
        addSubview(field)
        resize(field)
        window?.makeFirstResponder(field)
        textField = field
        model.selectedID = nil
        needsDisplay = true
    }

    private func resize(_ field: NSTextField) {
        let width = max(field.attributedStringValue.size().width + 24, 120)
        field.setFrameSize(NSSize(width: min(width, bounds.width - field.frame.minX - 8), height: field.frame.height))
    }

    func controlTextDidChange(_ notification: Notification) {
        if let field = notification.object as? NSTextField { resize(field) }
    }

    func controlTextDidEndEditing(_ notification: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            textField?.stringValue = editingText.flatMap { annotation -> String? in
                if case .text(_, let s) = annotation.shape { return s }
                return nil
            } ?? ""
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    /// Puts the text being typed onto the image (or drops it if it's empty).
    func commitText() {
        guard let field = textField, var annotation = editingText else { return }
        textField = nil
        editingText = nil
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        guard case .text(let position, _) = annotation.shape, !string.isEmpty else { needsDisplay = true; return }
        annotation.shape = .text(position, string)
        model.add(annotation)
        needsDisplay = true
    }
}

private struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> EditorCanvas {
        let canvas = EditorCanvas()
        canvas.model = model
        return canvas
    }

    func updateNSView(_ canvas: EditorCanvas, context: Context) {
        canvas.needsDisplay = true
    }
}

// MARK: - Window

@MainActor
final class EditorWindow: NSWindow, NSWindowDelegate {
    private static var open: [EditorWindow] = []
    private let model: EditorModel
    private var canvas: EditorCanvas? { contentView.flatMap { Self.find(EditorCanvas.self, in: $0) } }

    /// Opens the editor on a capture. Edits are saved as a new file; the original is never changed.
    static func open(_ capture: Capture, name: String? = nil) {
        let window = EditorWindow(model: EditorModel(image: capture.image, scale: capture.scale,
                                                     name: name ?? capture.fileName))
        open.append(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if let canvas = window.canvas { window.makeFirstResponder(canvas) }
    }

    private init(model: EditorModel) {
        self.model = model
        let visible = NSScreen.underMouse?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let imageSize = NSSize(width: CGFloat(model.base.width) / model.scale, height: CGFloat(model.base.height) / model.scale)
        let width = min(max(imageSize.width + 80, 760), visible.width * 0.85)
        let height = min(max(imageSize.height + 140, 520), visible.height * 0.85)
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Edit Capture"
        titleVisibility = .hidden // the toolbar sits in the title bar
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 640, height: 420)
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        delegate = self
        let hosting = NSHostingView(rootView: EditorView(model: model, actions: EditorActions(
            copy: { [weak self] in self?.copyResult() },
            save: { [weak self] in self?.saveAndClose() })))
        hosting.sizingOptions = [.minSize] // the window keeps the size chosen here
        contentView = hosting
        setContentSize(NSSize(width: width, height: height))
        center()
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    // MARK: Actions

    func copyResult() {
        canvas?.commitText()
        guard let capture = model.renderedCapture() else { return failed() }
        if capture.copyToClipboard() { Toast.show("Copied to clipboard") }
    }

    func saveAndClose() {
        canvas?.commitText()
        guard let capture = model.renderedCapture() else { return failed() }
        guard capture.saveReporting() else { return }
        if Prefs.copyToClipboard { capture.copyToClipboard() }
        model.markSaved()
        CaptureLibrary.shared.reload()
        close()
    }

    private func failed() {
        Toast.show("Couldn't create the edited image", symbol: "exclamationmark.triangle.fill")
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        // While typing text, the text field handles its own copy, paste and undo.
        if firstResponder is NSTextView { return super.performKeyEquivalent(with: event) }
        switch (key, flags.contains(.shift)) {
        case ("z", false): model.undo()
        case ("z", true): model.redo()
        case ("c", false): copyResult()
        case ("s", false): saveAndClose()
        case ("w", false): performClose(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        canvas?.needsDisplay = true
        return true
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas?.commitText()
        guard model.hasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Save your edits?"
        alert.informativeText = "They're saved as a new capture; the original stays as it is."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: self) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn: self.saveAndClose()
            case .alertThirdButtonReturn:
                self.model.markSaved()
                self.close()
            default: break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        // Free the image right away rather than whenever AppKit releases the window.
        DispatchQueue.main.async { [self] in
            contentView = nil
            EditorWindow.open.removeAll { $0 === self }
        }
    }
}

struct EditorActions {
    let copy: () -> Void
    let save: () -> Void
}

// MARK: - Toolbar

private struct EditorView: View {
    @ObservedObject var model: EditorModel
    let actions: EditorActions

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.leading, 80) // clear of the window buttons
                .padding(.trailing, 14)
                .frame(height: 52)
                .background(.bar)
            Divider()
            CanvasView(model: model)
        }
        .ignoresSafeArea()
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    ToolButton(tool: tool, selected: model.tool == tool) { model.tool = tool }
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.06)))

            if model.tool == .crop {
                Text("Drag to choose the area, then press Return").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelCrop() }
                Button("Apply Crop") { model.applyCrop() }.buttonStyle(.borderedProminent)
            } else {
                HStack(spacing: 5) {
                    ForEach(Array(EditorModel.palette.enumerated()), id: \.offset) { index, color in
                        Button { model.color = color } label: {
                            Circle()
                                .fill(Color(nsColor: color))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                                .padding(3)
                                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: model.color == color ? 2 : 0))
                        }
                        .buttonStyle(.plain)
                        .help("Color \(index + 1)")
                    }
                }

                Picker("Size", selection: $model.sizeIndex) {
                    Text("S").tag(0)
                    Text("M").tag(1)
                    Text("L").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 96)
                .help("Line and text size")

                HStack(spacing: 2) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.canUndo).help("Undo (⌘Z)")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!model.canRedo).help("Redo (⇧⌘Z)")
                }
                .buttonStyle(.borderless)

                if model.selectedID != nil {
                    Button { model.deleteSelected() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete (⌫)")
                }

                Spacer()
                Button(action: actions.copy) { Label("Copy", systemImage: "doc.on.doc").labelStyle(.titleAndIcon) }
                    .help("Copy the edited image (⌘C)")
                Button(action: actions.save) { Label("Save", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
                    .buttonStyle(.borderedProminent)
                    .help("Save as a new capture and close (⌘S)")
            }
        }
        .controlSize(.regular)
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : .clear))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tool.title) (\(String(tool.key).uppercased()))")
    }
}
