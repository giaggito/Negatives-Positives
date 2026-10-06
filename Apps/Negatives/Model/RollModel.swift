import AppKit
import CoreGraphics
import Foundation
import NegativesCore
import Observation
import simd
import UniformTypeIdentifiers

@Observable
final class Frame: Identifiable {
    let id = UUID()
    let url: URL
    var settings: FrameSettings
    var thumbnail: CGImage?
    var proxy: AnalysisProxy?

    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL, settings: FrameSettings) {
        self.url = url
        self.settings = settings
    }
}

enum Tool: Equatable {
    case none, filmBase, whiteBalance, crop
    /// Tools that need the whole, uncropped frame on screen.
    var showsFullFrame: Bool { self == .filmBase || self == .crop }
}

/// The open roll: frames, roll-level settings, the current frame and everything the editor shows.
@Observable
final class RollModel {
    // Roll
    private(set) var folder: URL?
    private(set) var frames: [Frame] = []
    var roll = RollSettings()
    private(set) var flat: FlatField?
    private var flatVersion = 0

    // Selection & editor state
    private(set) var selection: Int?
    var tool: Tool = .none { didSet { if tool != oldValue { requestRender() } } }
    var showBefore = false { didSet { requestRender() } }
    var zoomCentre: CGPoint? { didSet { requestRender() } }
    var showHistogram = true
    var showAdvanced = false
    var viewportPixels = CGSize(width: 1600, height: 1000) { didSet { if viewportPixels != oldValue { requestRender() } } }

    // Display
    private(set) var displayImage: CGImage?
    private(set) var displayOutputSize: CGSize = .zero
    private(set) var displayRegion: CGRect?
    private(set) var displayGeometry = FrameGeometry()
    private(set) var histogram: [SIMD3<Float>] = []
    private(set) var status: String?
    private(set) var isFullQuality = false

    // Export
    var exportProgress: Double?
    var exportMessage: String?

    private var decoded: DecodedFrame?
    private var clipboard: FrameSettings?
    private let processor: Processor
    private let renderer: EditorRenderer
    private let renderQueue = DispatchQueue(label: "negatives.render", qos: .userInteractive)
    private let decodeQueue = DispatchQueue(label: "negatives.decode", qos: .userInitiated)
    private let analysisQueue = DispatchQueue(label: "negatives.analysis", qos: .utility)
    private var renderBusy = false
    private var renderPending = false
    private var decodeToken = UUID()
    private var saveTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?

    init() {
        processor = try! Processor()
        renderer = EditorRenderer(gpu: processor.gpu)
    }

    /// Camera → linear sRGB of the decoded frame (for UI swatches).
    var cameraToSRGB: simd_double3x3? { decoded?.raw.cameraToSRGB }

    var current: Frame? { selection.flatMap { frames.indices.contains($0) ? frames[$0] : nil } }
    var hasRoll: Bool { !frames.isEmpty }

    // MARK: - Opening

    static func rawFiles(in urls: [URL]) -> [URL] { ScanFiles.collect(urls) }

    func open(_ urls: [URL]) {
        let files = Self.rawFiles(in: urls)
        guard !files.isEmpty else { status = "No RAW or image files found"; return }
        saveNow()
        renderQueue.sync { renderer.release() }
        decoded = nil
        displayImage = nil
        folder = files[0].deletingLastPathComponent()
        roll = Sidecar.load(RollSettings.self, from: Sidecar.rollURL(in: folder!)) ?? RollSettings()
        frames = files.map { Frame(url: $0, settings: Sidecar.load(FrameSettings.self, from: Sidecar.frameURL(for: $0)) ?? FrameSettings()) }
        flat = nil
        flatVersion += 1
        if let f = roll.flatFieldFile, let folder {
            loadFlatField(folder.appendingPathComponent(f), save: false)
        }
        NSDocumentController.shared.noteNewRecentDocumentURL(folder!)
        select(0)
        analyseRoll()
    }

    func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ScanFiles.extensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        panel.message = "Choose a roll folder, or scans of negatives (any camera RAW, TIFF or JPEG)"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    // MARK: - Analysis

    /// Loads analysis proxies (fast half-size decodes) for every frame, measures what is missing and
    /// pools the roll calibration. The current frame goes first so it can be shown quickly.
    private func analyseRoll() {
        let order = ([selection ?? 0] + frames.indices.filter { $0 != selection }).filter { frames.indices.contains($0) }
        let targets = order.map { frames[$0] }
        let flat = self.flat
        status = "Analysing roll…"
        analysisQueue.async { [weak self] in
            for (n, frame) in targets.enumerated() {
                guard let proxy = try? AnalysisProxy.load(frame.url, flat: flat) else { continue }
                DispatchQueue.main.async {
                    guard let self, self.frames.contains(where: { $0 === frame }) else { return }
                    frame.proxy = proxy
                    if self.roll.filmBase == nil {
                        Processor.measureFilmBase(proxy, file: frame.url.lastPathComponent, rect: nil, roll: &self.roll)
                    }
                    // Frames measured by older versions (no statistics) are measured again.
                    if frame.settings.stats == nil { Processor.measureAnchors(proxy, roll: self.roll, settings: &frame.settings) }
                    if frame === self.current { self.requestRender() }
                    self.updateThumbnail(frame)
                    if n == targets.count - 1 { self.finishRollAnalysis() }
                }
            }
        }
    }

    private func finishRollAnalysis() {
        if roll.calibration == nil || roll.version < RollSettings.currentVersion { recalibrate() }
        status = nil
        scheduleSave()
    }

    /// Re-pools the roll calibration from every frame's statistics and refreshes everything.
    func recalibrate() {
        Processor.analyzeRoll(&roll, frames: frames.map(\.settings))
        refreshAll()
    }

    /// Re-measures every frame (after the film base or flat field changed).
    func remeasureAll() {
        for f in frames {
            guard let p = f.proxy else { continue }
            Processor.measureAnchors(p, roll: roll, settings: &f.settings)
        }
        recalibrate()
    }

    private func refreshAll() {
        requestRender()
        scheduleSave()
        thumbTask?.cancel()
        thumbTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for f in self.frames {
                if Task.isCancelled { return }
                self.updateThumbnail(f)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - Selection & decoding

    func select(_ index: Int) {
        guard frames.indices.contains(index), index != selection || decoded == nil else { return }
        selection = index
        zoomCentre = nil
        if tool == .crop || tool == .filmBase { tool = .none }
        let frame = frames[index]
        let token = UUID()
        decodeToken = token
        isFullQuality = false
        status = "Opening \(frame.name)…"
        // Fast 1-pass demosaic first (≈1 s), then the 3-pass version for fine detail (same colours).
        decodeQueue.async { [weak self] in
            for quality in [DemosaicQuality.fast, .best] {
                guard let d = try? DecodedFrame.decode(frame.url, quality: quality) else {
                    DispatchQueue.main.async { self?.status = "Could not read \(frame.url.lastPathComponent)" }
                    return
                }
                var stale = false
                DispatchQueue.main.sync {
                    guard let self, self.decodeToken == token else { stale = true; return }
                    self.decoded = d
                    self.isFullQuality = quality == .best
                    self.status = quality == .best ? nil : self.status
                    self.requestRender()
                }
                if stale { return }
            }
        }
    }

    func selectNext() { if let s = selection, s + 1 < frames.count { select(s + 1) } }
    func selectPrevious() { if let s = selection, s > 0 { select(s - 1) } }

    // MARK: - Editing

    /// Mutates the current frame's settings and refreshes. `remeasure` re-measures the frame (crop changes).
    func edit(remeasure: Bool = false, _ change: (inout FrameSettings) -> Void) {
        guard let f = current else { return }
        var s = f.settings
        change(&s)
        guard s != f.settings else { return }
        f.settings = s
        if remeasure, let p = f.proxy {
            Processor.measureAnchors(p, roll: roll, settings: &f.settings)
            Processor.analyzeRoll(&roll, frames: frames.map(\.settings))
            refreshAll()
            return
        }
        requestRender()
        scheduleSave()
        scheduleThumbnail(f)
    }

    func editRoll(_ change: (inout RollSettings) -> Void) {
        var r = roll
        change(&r)
        guard r != roll else { return }
        roll = r
        refreshAll()
    }

    func copySettings() { clipboard = current?.settings }
    var canPaste: Bool { clipboard != nil }

    func pasteSettings(toAll: Bool = false) {
        guard let c = clipboard else { return }
        for f in toAll ? frames : [current].compactMap({ $0 }) { f.settings = c.pastingLook(onto: f.settings) }
        refreshAll()
    }

    func resetLook() {
        edit { s in
            let fresh = FrameSettings()
            s = fresh.pastingLook(onto: s)
        }
    }

    func rotate(clockwise: Bool) {
        edit(remeasure: true) { s in
            s.geometry.quarterTurns = (s.geometry.quarterTurns + (clockwise ? 1 : 3)) % 4
            // Keep the crop on the same part of the picture.
            let c = s.geometry.crop
            s.geometry.crop = clockwise ? CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
                                        : CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
        }
    }

    func flip(horizontal: Bool) {
        edit(remeasure: true) { s in
            // Flips act in sensor space; on screen they appear along the rotated axis.
            let screenHorizontal = s.geometry.quarterTurns % 2 == 0 ? horizontal : !horizontal
            if screenHorizontal { s.geometry.flipHorizontal.toggle() } else { s.geometry.flipVertical.toggle() }
            let c = s.geometry.crop
            s.geometry.crop = horizontal ? CGRect(x: 1 - c.maxX, y: c.minY, width: c.width, height: c.height)
                                         : CGRect(x: c.minX, y: 1 - c.maxY, width: c.width, height: c.height)
        }
    }

    // MARK: - Tools

    /// Converts a point in normalised display coordinates (0…1 over the shown image) to sensor pixels.
    func sensorPoint(normalized p: CGPoint) -> SIMD2<Double>? {
        guard let d = decoded else { return nil }
        let raw = d.raw.image
        let out: CGPoint
        if let r = displayRegion {
            out = CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
        } else {
            out = CGPoint(x: p.x * displayOutputSize.width, y: p.y * displayOutputSize.height)
        }
        return displayGeometry.outputToSource(sourceWidth: raw.width, sourceHeight: raw.height).apply([out.x, out.y])
    }

    /// Film base from a rectangle drawn in normalised display coordinates.
    func setFilmBase(normalizedRect r: CGRect) {
        guard let f = current, let p = f.proxy, let d = decoded else { return }
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        let pts = corners.compactMap { sensorPoint(normalized: $0) }
        guard pts.count == 4 else { return }
        let W = Double(d.raw.image.width), H = Double(d.raw.image.height)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let rect = CGRect(x: xs.min()! / W, y: ys.min()! / H, width: (xs.max()! - xs.min()!) / W, height: (ys.max()! - ys.min()!) / H)
        guard rect.width > 0.002, rect.height > 0.002 else { return }
        if Processor.measureFilmBase(p, file: f.url.lastPathComponent, rect: rect, roll: &roll) {
            if let c = roll.filmBaseClipped, c > 0.01 {
                status = "Film base is clipped: lower the camera exposure when scanning"
            }
            remeasureAll()
        }
        tool = .none
    }

    func autoFilmBase() {
        guard let f = current, let p = f.proxy else { return }
        if Processor.measureFilmBase(p, file: f.url.lastPathComponent, rect: nil, roll: &roll) { remeasureAll() }
    }

    /// White-balance eyedropper: makes the clicked point neutral.
    func pickNeutral(normalized p: CGPoint) {
        guard let f = current, let proxy = f.proxy, let d = decoded, let s = sensorPoint(normalized: p) else { return }
        var neutral = f.settings
        neutral.whiteBalance = .neutral
        guard let params = try? ConversionParameters.resolve(roll: roll, frame: neutral, cameraToRec2020: d.raw.cameraToRec2020) else { return }
        // Average a small neighbourhood (≈ 24 sensor pixels) so grain doesn't decide.
        var acc = SIMD3<Double>.zero
        for dy in -1...1 { for dx in -1...1 { acc += proxy.sample(sensor: s + SIMD2(Double(dx * 8), Double(dy * 8))) } }
        let scene = NegativeModel.sceneLinear(acc / 9, params)
        if let wb = WhiteBalance.neutralizing(scene) { edit { $0.whiteBalance = wb } }
        tool = .none
    }

    func toggleZoom(at normalized: CGPoint? = nil) {
        if zoomCentre != nil { zoomCentre = nil; return }
        let p = normalized ?? CGPoint(x: 0.5, y: 0.5)
        zoomCentre = CGPoint(x: p.x * displayOutputSize.width, y: p.y * displayOutputSize.height)
    }

    func panZoom(by delta: CGSize) {
        guard var c = zoomCentre else { return }
        c.x = min(max(0, c.x - delta.width), displayOutputSize.width)
        c.y = min(max(0, c.y - delta.height), displayOutputSize.height)
        zoomCentre = c
    }

    // MARK: - Flat field

    func chooseFlatField() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScanFiles.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a shot of the bare light panel (same setup, no film)"
        panel.directoryURL = folder
        if panel.runModal() == .OK, let u = panel.url { loadFlatField(u, save: true) }
    }

    func clearFlatField() {
        flat = nil
        flatVersion += 1
        processor.flat = nil
        roll.flatFieldFile = nil
        rebuildProxies()
    }

    private func loadFlatField(_ url: URL, save: Bool) {
        guard let raw = try? RawDecoder.decodeAny(url: url, quality: .half) else { status = "Could not read the flat-field file"; return }
        let ff = FlatField(panel: raw)
        flat = ff
        flatVersion += 1
        processor.flat = ff
        if save {
            roll.flatFieldFile = url.path.hasPrefix(folder?.path ?? "\u{0}") ? url.lastPathComponent : url.path
            rebuildProxies()
        }
    }

    private func rebuildProxies() {
        for f in frames {
            guard let p = f.proxy else { continue }
            f.proxy = AnalysisProxy(image: p.image, sourceWidth: p.sourceWidth, sourceHeight: p.sourceHeight, clipLevel: p.clipLevel, flat: flat)
        }
        if let src = roll.filmBaseSource, let f = frames.first(where: { $0.url.lastPathComponent == src.file }), let p = f.proxy {
            Processor.measureFilmBase(p, file: src.file, rect: src.rect, roll: &roll)
        }
        remeasureAll()
    }

    // MARK: - Rendering

    func parameters(for f: Frame, raw: RawImage? = nil) -> ConversionParameters? {
        let m = (raw ?? decoded?.raw)?.cameraToRec2020 ?? ColorScience.sRGBToRec2020
        return try? ConversionParameters.resolve(roll: roll, frame: f.settings, cameraToRec2020: m)
    }

    func requestRender() {
        renderPending = true
        if !renderBusy { startRender() }
    }

    private func startRender() {
        renderPending = false
        guard let f = current, let d = decoded, d.url == f.url, let params = parameters(for: f) else { return }
        var geometry = f.settings.geometry
        if tool.showsFullFrame { geometry.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
        let job = RenderJob(frame: d, parameters: params, geometry: geometry, stage: showBefore ? .negative : .positive,
                            fit: viewportPixels, zoomCentre: tool.showsFullFrame ? nil : zoomCentre, flat: flat, flatVersion: flatVersion)
        renderBusy = true
        renderQueue.async { [weak self] in
            guard let self else { return }
            let result = try? self.renderer.render(job)
            DispatchQueue.main.async {
                if let result {
                    self.displayImage = result.image
                    self.histogram = result.histogram
                    self.displayOutputSize = result.outputSize
                    self.displayRegion = result.region
                    self.displayGeometry = job.geometry
                }
                self.renderBusy = false
                if self.renderPending { self.startRender() }
            }
        }
    }

    private var thumbDebounce: [UUID: Task<Void, Never>] = [:]

    private func scheduleThumbnail(_ f: Frame) {
        thumbDebounce[f.id]?.cancel()
        thumbDebounce[f.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !Task.isCancelled { self?.updateThumbnail(f) }
        }
    }

    private func updateThumbnail(_ f: Frame) {
        guard let p = f.proxy, let params = parameters(for: f) else { return }
        let g = f.settings.geometry
        renderQueue.async { [weak self] in
            guard let self else { return }
            let t = try? self.renderer.thumbnail(proxy: p, parameters: params, geometry: g, maxSize: 360)
            DispatchQueue.main.async { f.thumbnail = t }
        }
    }

    // MARK: - Saving

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if !Task.isCancelled { self?.saveNow() }
        }
    }

    func saveNow() {
        guard let folder else { return }
        try? Sidecar.save(roll, to: Sidecar.rollURL(in: folder))
        for f in frames { try? Sidecar.save(f.settings, to: Sidecar.frameURL(for: f.url)) }
    }

    // MARK: - Export

    func export(frames toExport: [Frame], to dir: URL, format: ExportFormat, space: OutputColorSpace) {
        saveNow()
        let roll = self.roll
        let processor = self.processor
        let jobs = toExport.map { ($0.url, $0.settings) }
        exportProgress = 0
        exportMessage = "Exporting…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            var clippedNote = false
            for (i, (url, settings)) in jobs.enumerated() {
                DispatchQueue.main.async { self?.exportMessage = "Exporting \(url.deletingPathExtension().lastPathComponent) (\(i + 1)/\(jobs.count))" }
                do {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let frame = try DecodedFrame.decode(url, quality: .best)
                    let img = try processor.render(frame, roll: roll, settings: settings)
                    let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "." + format.fileExtension)
                    let report = try Exporter.write(img, to: out, format: format, space: space)
                    if report.clippedFraction > 0.001 { clippedNote = true }
                } catch {
                    failures.append(url.lastPathComponent)
                }
                DispatchQueue.main.async { self?.exportProgress = Double(i + 1) / Double(jobs.count) }
            }
            DispatchQueue.main.async {
                self?.exportProgress = nil
                if !failures.isEmpty {
                    self?.exportMessage = "Could not export: \(failures.joined(separator: ", "))"
                } else {
                    self?.exportMessage = "Exported \(jobs.count) frame\(jobs.count == 1 ? "" : "s")"
                        + (clippedNote ? " — some colours exceeded \(space.displayName); ProPhoto keeps them" : "")
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
                Task { @MainActor in try? await Task.sleep(nanoseconds: 6_000_000_000); self?.exportMessage = nil }
            }
        }
    }
}
