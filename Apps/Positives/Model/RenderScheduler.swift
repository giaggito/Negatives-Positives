import CoreGraphics
import Foundation
import os
import PositivesCore

/// Runs the render engine on its own queue and always works on the newest request: requests that arrive
/// while a frame is rendering replace each other, so the picture follows the slider without a backlog.
///
/// Each request is rendered in up to three steps:
/// 1. the visible region on the fast path (what you see while dragging, ≈60+ fps),
/// 2. when zoomed in, a small whole-picture overview (histogram, and something to show while panning),
/// 3. once nothing moves any more: the exact render of the visible region (full resolution, area-averaged —
///    the export, smaller). It is abandoned band by band as soon as a newer request arrives.
final class RenderScheduler: @unchecked Sendable {
    struct Request {
        var source: SourceImage
        var edit: EditState
        var viewport: Viewport
        var interacting: Bool
        var interactiveGeometry: Bool
        var version: Int
        var histogramSpace: OutputColorSpace
        var wantsThumbnail: Bool
        var overlayTarget: Int?
        var overlayMask: Int?
    }

    struct Result {
        var version: Int
        var main: RenderedView?
        var overview: RenderedView?
        var histogram: Histogram?
        var exact: Bool
        var thumbnail: CGImage?
        var frameTime: Double
    }

    let engine: RenderEngine
    private let queue = DispatchQueue(label: "positives.render", qos: .userInteractive)
    private let lock = OSAllocatedUnfairLock<Request?>(initialState: nil)
    private var running = false   // main thread only
    private var lastOverview = Date.distantPast   // render queue only
    /// While a slider moves, frames that would miss 60 fps are rendered as drafts at a lower resolution
    /// (in steps, so the per-view caches stay valid); the exact picture follows on release. Render queue only.
    private var draftLevel = 0
    static let draftFactors: [Double] = [1, 0.84, 0.71, 0.6, 0.5]
    static let frameBudget = 0.0135
    var onResult: ((Result) -> Void)?

    init(engine: RenderEngine) { self.engine = engine }

    /// Main thread.
    func submit(_ r: Request) {
        lock.withLock { $0 = r }
        if !running { pump() }
    }

    private var hasPending: Bool { lock.withLock { $0 != nil } }

    private func pump() {
        guard let r = lock.withLock({ s -> Request? in let v = s; s = nil; return v }) else { running = false; return }
        running = true
        queue.async { [weak self] in
            guard let self else { return }
            self.render(r)
            DispatchQueue.main.async { self.pump() }
        }
    }

    /// Runs `body` on the render queue (eyedropper sampling and other engine reads), in order with frames.
    func perform(_ body: @escaping (RenderEngine) -> Void) {
        queue.async { [engine] in body(engine) }
    }

    private func deliver(_ res: Result) {
        DispatchQueue.main.async { [weak self] in self?.onResult?(res) }
    }

    private func render(_ r: Request) {
        let t0 = Date()
        do {
            try engine.setSource(r.source)
            let full = engine.outputSize(r.edit.geometry)
            let vp = r.viewport
            let m = vp.magnification
            let scale = min(1, m)
            // Render a margin of screen pixels around the visible area so small pans need nothing new
            // (smaller while a slider is dragged: every pixel counts then).
            let margin = (r.interacting ? 24 : 128) / m
            var region = vp.visible.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: full))
            if scale >= 1 { region = region.integral.intersection(CGRect(origin: .zero, size: full)) }
            if region.isEmpty { region = CGRect(origin: .zero, size: full) }
            let wholeVisible = region.width >= full.width - 1 && region.height >= full.height - 1
            let renderScale = r.interacting ? scale * Self.draftFactors[draftLevel] : scale
            let tMain = Date()
            let main = try engine.render(r.edit, view: ViewRequest(region: region, scale: renderScale, exact: false),
                                         interactiveGeometry: r.interactiveGeometry,
                                         histogramSpace: wholeVisible ? r.histogramSpace : nil, slot: 0, overlayTarget: r.overlayTarget, overlayMask: r.overlayMask,
                                         fastGrain: r.interacting || vp.moving, fastLayers: r.interacting)
            if r.interacting {
                // Adapt the draft level to the frame time (with hysteresis so it does not flicker).
                let t = Date().timeIntervalSince(tMain)
                if t > Self.frameBudget * 1.15, draftLevel < Self.draftFactors.count - 1 { draftLevel += 1 }
                else if draftLevel > 0, t * pow(Self.draftFactors[draftLevel - 1] / Self.draftFactors[draftLevel], 2) < Self.frameBudget * 0.85 {
                    draftLevel -= 1
                }
            }
            var overview: RenderedView?
            // While dragging zoomed in, the whole-picture overview (histogram, panning backdrop) is refreshed
            // a few times a second instead of every frame.
            if !wholeVisible && (!r.interacting || Date().timeIntervalSince(lastOverview) > 0.2) {
                lastOverview = Date()
                let os = min(1, 1600 / max(full.width, full.height))
                overview = try engine.render(r.edit, view: ViewRequest(region: CGRect(origin: .zero, size: full), scale: os, exact: false),
                                             interactiveGeometry: r.interactiveGeometry, histogramSpace: r.histogramSpace, slot: 1,
                                             overlayTarget: r.overlayTarget, overlayMask: r.overlayMask, fastLayers: r.interacting)
            }
            let fast = Result(version: r.version, main: main, overview: overview, histogram: wholeVisible ? main.histogram : overview?.histogram,
                              exact: main.exact, thumbnail: nil, frameTime: Date().timeIntervalSince(t0))
            deliver(fast)

            guard !r.interacting, !vp.moving, !r.interactiveGeometry, !hasPending else { return }
            var final = main
            if !main.exact {
                guard let exact = try engine.renderExact(r.edit, view: ViewRequest(region: region, scale: scale, exact: true),
                                                         histogramSpace: wholeVisible ? r.histogramSpace : nil, slot: 0,
                                                         overlayTarget: r.overlayTarget, overlayMask: r.overlayMask, cancel: { [weak self] in self?.hasPending ?? true })
                else { return }
                final = exact
                deliver(Result(version: r.version, main: exact, overview: nil, histogram: exact.histogram, exact: true, thumbnail: nil,
                               frameTime: Date().timeIntervalSince(t0)))
            }
            if r.wantsThumbnail, !hasPending {
                let thumbSource = wholeVisible ? final : (overview ?? final)
                let img = try engine.snapshot(thumbSource, maxSize: 400)
                deliver(Result(version: r.version, main: nil, overview: nil, histogram: nil, exact: true, thumbnail: img.makeCGImage(), frameTime: 0))
            }
        } catch {
            NSLog("Positives render failed: \(error)")
        }
    }
}
