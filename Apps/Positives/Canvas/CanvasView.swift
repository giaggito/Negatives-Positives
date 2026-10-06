import AppKit
import Metal
import PositivesCore
import QuartzCore
import simd
import SwiftUI

/// What part of the picture is on screen.
struct Viewport: Equatable {
    /// Visible part of the image, in full-resolution output pixels.
    var visible: CGRect
    /// Screen (device) pixels per image pixel.
    var magnification: Double
    /// True while a pinch / scroll / zoom animation is in progress.
    var moving: Bool
}

/// Where the image sits in the canvas, for SwiftUI overlays (view points, y down).
@Observable final class CanvasState {
    var imageFrame: CGRect = .zero
    var magnification: Double = 1
    var isFit = true
}

/// The photo canvas: Apple's own scroll view supplies the gestures and physics (pinch anchored under the
/// fingers, momentum, rubber-banding, smart zoom), a Metal layer behind it draws the float image.
final class CanvasView: NSView {
    static let padding: CGFloat = 28

    let scrollView = CanvasScrollView()
    let documentView = CanvasDocumentView()
    let metalView = MetalLayerView()
    private var renderer: DisplayRenderer?

    var state: CanvasState?
    var onViewport: ((Viewport) -> Void)?
    var onClick: ((CGPoint) -> Void)?          // image px
    var onDraw: ((CanvasDrawPhase, CGPoint, NSEvent.ModifierFlags) -> Void)?   // image px
    var onHover: ((CGPoint?) -> Void)?         // image px
    var clickTool = false { didSet { documentView.clickTool = clickTool; window?.invalidateCursorRects(for: documentView) } }
    func setDrawTool(_ on: Bool, brush: Bool) {
        documentView.drawTool = on
        documentView.brushCursor = brush
        window?.invalidateCursorRects(for: documentView)
    }
    /// Off while cropping: the whole frame always fits the view. The fit is immediate, never animated — the crop
    /// bar shrinks the view at the same moment, and an animation still running toward the old size would leave
    /// the picture too large, its edges hidden and out of the crop's reach.
    var zoomEnabled = true { didSet { scrollView.allowsMagnification = zoomEnabled; if !zoomEnabled { fit(animated: false) } } }

    private(set) var imageSize: CGSize = .zero
    private var main: RenderedView?
    private var overview: RenderedView?
    var showClipping = false { didSet { redraw() } }
    var outputMatrix = simd_float3x3(OutputColorSpace.sRGB.fromRec2020) { didSet { redraw() } }
    private var isFit = true
    private var moving = false
    private var movingTimer: Timer?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        addSubview(metalView)
        addSubview(scrollView)
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = documentView
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.02
        scrollView.maxMagnification = 8
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveStart), name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveEnd), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveStart), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        NotificationCenter.default.addObserver(self, selector: #selector(liveEnd), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        scrollView.onSmartZoom = { [weak self] p in self?.toggleZoom(at: p) }
        documentView.onDoubleClick = { [weak self] p in self?.toggleZoom(at: p) }
        documentView.onClick = { [weak self] p in
            guard let self else { return }
            self.onClick?(CGPoint(x: p.x * self.backingScale, y: p.y * self.backingScale))
        }
        documentView.onDraw = { [weak self] phase, p, mods in
            guard let self else { return }
            self.onDraw?(phase, CGPoint(x: p.x * self.backingScale, y: p.y * self.backingScale), mods)
        }
        documentView.onHover = { [weak self] p in
            guard let self else { return }
            self.onHover?(p.map { CGPoint(x: $0.x * self.backingScale, y: $0.y * self.backingScale) })
        }
        if let ctx = MetalContext.shared { renderer = try? DisplayRenderer(context: ctx); metalView.metalLayer.device = ctx.device }
    }

    required init?(coder: NSCoder) { fatalError() }

    var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        scrollView.frame = bounds
        metalView.metalLayer.contentsScale = backingScale
        metalView.metalLayer.drawableSize = CGSize(width: bounds.width * backingScale, height: bounds.height * backingScale)
        updateLimits()
        if isFit || !zoomEnabled { fit(animated: false) }
        redraw()
        publish()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setImageSize(imageSize, refit: isFit)
    }

    // MARK: Content

    /// Sets the size of the picture (output pixels). The view stays where it was unless `refit`.
    func setImageSize(_ size: CGSize, refit: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        let changed = size != imageSize
        imageSize = size
        documentView.frame = CGRect(origin: .zero, size: CGSize(width: size.width / backingScale, height: size.height / backingScale))
        updateLimits()
        if refit || (changed && isFit) { fit(animated: false) }
        boundsChanged()
    }

    func show(main: RenderedView?, overview: RenderedView?) {
        if let main { self.main = main }
        if let overview { self.overview = overview }
        redraw()
    }

    func clearContent() { main = nil; overview = nil; redraw() }

    // MARK: Zoom

    var fitMagnification: CGFloat {
        let docSize = documentView.frame.size
        guard docSize.width > 0, docSize.height > 0 else { return 1 }
        let w = max(1, bounds.width - 2 * Self.padding), h = max(1, bounds.height - 2 * Self.padding)
        return min(min(w / docSize.width, h / docSize.height), 8)
    }

    private func updateLimits() {
        scrollView.minMagnification = min(fitMagnification, 1) * 0.999
    }

    func fit(animated: Bool) {
        isFit = true
        let target = fitMagnification
        let centre = CGPoint(x: documentView.frame.midX, y: documentView.frame.midY)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.animator().setMagnification(target, centeredAt: centre)
            }
        } else {
            scrollView.setMagnification(target, centeredAt: centre)
        }
    }

    /// Zooms to `level` (screen pixels per image pixel, 1 = 100 %) keeping `point` (document coordinates) still.
    func zoom(to level: CGFloat, at point: CGPoint? = nil, animated: Bool = true) {
        guard zoomEnabled else { return }
        isFit = false
        let p = point ?? CGPoint(x: scrollView.contentView.bounds.midX, y: scrollView.contentView.bounds.midY)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                scrollView.animator().setMagnification(level, centeredAt: p)
            }
        } else {
            scrollView.setMagnification(level, centeredAt: p)
        }
    }

    /// Smart zoom: fit ↔ 100 % under the pointer.
    func toggleZoom(at point: CGPoint? = nil) {
        guard zoomEnabled else { return }
        if scrollView.magnification > fitMagnification * 1.02 { fit(animated: true) } else { zoom(to: 1, at: point) }
    }

    func zoomStep(_ factor: CGFloat) {
        guard zoomEnabled else { return }
        let stops: [CGFloat] = [0.0625, 0.125, 0.25, 0.333, 0.5, 0.667, 1, 2, 3, 4, 6, 8]
        let m = scrollView.magnification
        let next = factor > 1 ? stops.first { $0 > m * 1.01 } : stops.last { $0 < m * 0.99 }
        if let n = next {
            if n <= fitMagnification && factor < 1 { fit(animated: true) } else { zoom(to: max(n, fitMagnification)) }
        }
    }

    // MARK: Viewport

    @objc private func boundsChanged() {
        if zoomEnabled, abs(scrollView.magnification - fitMagnification) > 0.001 { isFit = false }
        redraw()
        publish()
        reportViewport()
    }

    @objc private func liveStart() { setMoving(true) }
    @objc private func liveEnd() { setMoving(false) }

    private func setMoving(_ m: Bool) {
        movingTimer?.invalidate()
        if m { moving = true; reportViewport(); return }
        // Momentum and zoom animations keep moving after the gesture: settle once bounds are quiet.
        movingTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            self?.moving = false
            self?.reportViewport()
        }
    }

    private func reportViewport() {
        guard imageSize.width > 0 else { return }
        let bs = backingScale
        let r = scrollView.contentView.bounds.intersection(documentView.bounds)
        let visible = CGRect(x: r.minX * bs, y: r.minY * bs, width: r.width * bs, height: r.height * bs)
        onViewport?(Viewport(visible: visible, magnification: scrollView.magnification, moving: moving))
        if moving {
            movingTimer?.invalidate()
            movingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.moving = false
                self?.reportViewport()
            }
        }
    }

    private func publish() {
        guard let state else { return }
        let f = documentView.convert(documentView.bounds, to: self)
        if state.imageFrame != f { state.imageFrame = f }
        if state.magnification != scrollView.magnification { state.magnification = scrollView.magnification }
        if state.isFit != isFit { state.isFit = isFit }
    }

    /// The canvas as currently drawn, offscreen (self-test).
    func snapshot() -> CGImage? {
        guard let renderer, let f = currentFrame() else { return nil }
        let w = Int(bounds.width * backingScale), h = Int(bounds.height * backingScale)
        guard let t = renderer.drawOffscreen(f, width: w, height: h) else { return nil }
        var half = [UInt16](repeating: 0, count: w * h * 4)
        half.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
        let data = half.withUnsafeBytes { Data($0) } as CFData
        return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                       space: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
                       provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func currentFrame() -> DisplayRenderer.Frame? {
        guard imageSize.width > 0 else { return nil }
        let bs = backingScale
        let o = documentView.convert(CGPoint.zero, to: self)
        return DisplayRenderer.Frame(
            origin: SIMD2(Float(o.x * bs), Float(o.y * bs)),
            magnification: Float(scrollView.magnification),
            imageSize: SIMD2(Float(imageSize.width), Float(imageSize.height)),
            main: main, overview: overview, background: linearCanvasColour, showClipping: showClipping, outputMatrix: outputMatrix)
    }

    func redraw() {
        guard let renderer, imageSize.width > 0 else { return }
        let bs = backingScale
        let o = documentView.convert(CGPoint.zero, to: self)
        let bg = linearCanvasColour
        renderer.draw(DisplayRenderer.Frame(
            origin: SIMD2(Float(o.x * bs), Float(o.y * bs)),
            magnification: Float(scrollView.magnification),
            imageSize: SIMD2(Float(imageSize.width), Float(imageSize.height)),
            main: main, overview: overview, background: bg, showClipping: showClipping, outputMatrix: outputMatrix),
                      in: metalView.metalLayer)
    }

    /// Theme.canvas (sRGB 0.105 grey) in linear light.
    private let linearCanvasColour = SIMD3<Float>(repeating: Float(OutputColorSpace.sRGB.decode(0.105)))
}

/// Scroll view that hands two-finger double-taps (smart magnify) to the canvas.
final class CanvasScrollView: NSScrollView {
    var onSmartZoom: ((CGPoint) -> Void)?
    override func smartMagnify(with event: NSEvent) {
        guard allowsMagnification, let doc = documentView else { return }
        onSmartZoom?(doc.convert(event.locationInWindow, from: nil))
    }
}

/// Keeps the picture centred when it is smaller than the window, on whole device pixels.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        let f = doc.frame
        if r.width > f.width { r.origin.x = (f.width - r.width) / 2 }
        if r.height > f.height { r.origin.y = (f.height - r.height) / 2 }
        // Snap to device pixels so the rendered texture lines up with the screen grid.
        let scale = (window?.backingScaleFactor ?? 2) * (enclosingScrollView?.magnification ?? 1)
        r.origin.x = (r.origin.x * scale).rounded() / scale
        r.origin.y = (r.origin.y * scale).rounded() / scale
        return r
    }
}

/// Transparent document: sets the scrollable size and takes the clicks (pan, smart zoom, tools).
final class CanvasDocumentView: NSView {
    var onDoubleClick: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDraw: ((CanvasDrawPhase, CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    var clickTool = false
    /// Drags paint / draw (masks) instead of panning; `brushCursor` hides the arrow (the brush outline shows).
    var drawTool = false
    var brushCursor = false
    private var drawing = false
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) { onHover?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    private var dragStart: NSPoint?
    private var dragOrigin: NSPoint = .zero
    private var dragged = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: clickTool || (drawTool && !brushCursor) ? .crosshair : (drawTool ? Self.dotCursor : .arrow))
    }

    /// A small dot: the brush outline is drawn by the mask overlay around it.
    static let dotCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 7, height: 7), flipped: false) { r in
            NSColor.black.withAlphaComponent(0.6).setFill(); NSBezierPath(ovalIn: r).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 3.5, y: 3.5))
    }()

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if drawTool {
            drawing = true
            onDraw?(.began, p, event.modifierFlags)
            return
        }
        if event.clickCount == 2 && !clickTool { onDoubleClick?(p); return }
        dragStart = event.locationInWindow
        dragOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        if drawing {
            let p = convert(event.locationInWindow, from: nil)
            onHover?(p)
            onDraw?(.changed, p, event.modifierFlags)
            return
        }
        guard let start = dragStart, let sv = enclosingScrollView else { return }
        let dx = event.locationInWindow.x - start.x, dy = event.locationInWindow.y - start.y
        if abs(dx) + abs(dy) > 3 { dragged = true }
        guard dragged else { return }
        NSCursor.closedHand.set()
        let m = sv.magnification
        let clip = sv.contentView
        // Window y points up; the document is flipped.
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: dragOrigin.x - dx / m, y: dragOrigin.y + dy / m), size: clip.bounds.size)).origin)
        sv.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if drawing {
            drawing = false
            onDraw?(.ended, convert(event.locationInWindow, from: nil), event.modifierFlags)
            return
        }
        defer { dragStart = nil; window?.invalidateCursorRects(for: self) }
        if !dragged && event.clickCount == 1 && clickTool { onClick?(convert(event.locationInWindow, from: nil)) }
    }
}

final class MetalLayerView: NSView {
    let metalLayer = CAMetalLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        metalLayer.wantsExtendedDynamicRangeContent = false
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.presentsWithTransaction = false
        layer = metalLayer
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

/// SwiftUI wrapper. The model drives the view through `CanvasController`.
struct PhotoCanvas: NSViewRepresentable {
    let controller: CanvasController
    let state: CanvasState

    func makeNSView(context: Context) -> CanvasView {
        let v = CanvasView(frame: .zero)
        v.state = state
        controller.attach(v)
        return v
    }

    func updateNSView(_ nsView: CanvasView, context: Context) {}
}

/// Commands from the model to the canvas.
final class CanvasController {
    private(set) weak var view: CanvasView?
    var onViewport: ((Viewport) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDraw: ((CanvasDrawPhase, CGPoint, NSEvent.ModifierFlags) -> Void)?
    var onHover: ((CGPoint?) -> Void)?
    private var pendingSize: (CGSize, Bool)?
    private var drawTool = (false, false)

    func attach(_ v: CanvasView) {
        view = v
        v.onViewport = { [weak self] in self?.onViewport?($0) }
        v.onClick = { [weak self] in self?.onClick?($0) }
        v.onDraw = { [weak self] in self?.onDraw?($0, $1, $2) }
        v.onHover = { [weak self] in self?.onHover?($0) }
        v.setDrawTool(drawTool.0, brush: drawTool.1)
        if let (s, f) = pendingSize { v.setImageSize(s, refit: f) }
    }

    func setImageSize(_ s: CGSize, refit: Bool) {
        pendingSize = (s, refit)
        view?.setImageSize(s, refit: refit)
    }
    func show(main: RenderedView?, overview: RenderedView?) { view?.show(main: main, overview: overview) }
    func clear() { view?.clearContent() }
    func fit() { view?.fit(animated: true) }
    func zoom(to level: CGFloat) { view?.zoom(to: level) }
    func toggleZoom() { view?.toggleZoom() }
    func zoomStep(_ f: CGFloat) { view?.zoomStep(f) }
    func setClickTool(_ on: Bool) { view?.clickTool = on }
    func setDrawTool(_ on: Bool, brush: Bool) { drawTool = (on, brush); view?.setDrawTool(on, brush: brush) }
    func setZoomEnabled(_ on: Bool) { view?.zoomEnabled = on }
    func setClipping(_ on: Bool, matrix: simd_float3x3) { view?.outputMatrix = matrix; view?.showClipping = on }
    func snapshot() -> CGImage? { view?.snapshot() }
}
