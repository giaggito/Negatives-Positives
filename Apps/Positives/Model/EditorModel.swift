import AppKit
import Foundation
import Metal
import Observation
import PositivesCore
import simd
import UniformTypeIdentifiers

/// One photo in the open folder.
@Observable final class PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    var thumbnail: CGImage?
    var edited: Bool
    init(url: URL) {
        self.url = url
        self.edited = Archive.shared.entry(for: url) != nil
    }
}

struct HistoryEntry: Identifiable {
    let id = UUID()
    var label: String
    var state: EditState
    var date = Date()
}

enum Tool: Equatable { case none, crop, whiteBalance, targetColor, curvePoint, maskColor }

/// The inspector's pages, like the sections of Photos' Adjust panel.
enum InspectorCategory: Int, CaseIterable, Identifiable {
    case light, color, curves, film, effects, masks, layers, history
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .light: return "Light"
        case .color: return "Color"
        case .curves: return "Curves"
        case .film: return "Film"
        case .effects: return "Effects"
        case .masks: return "Masks"
        case .layers: return "Layers"
        case .history: return "History"
        }
    }
    var symbol: String {
        switch self {
        case .light: return "sun.max"
        case .color: return "paintpalette"
        case .curves: return "chart.xyaxis.line"
        case .film: return "film"
        case .effects: return "sparkles"
        case .masks: return "theatermask.and.paintbrush"
        case .layers: return "square.2.layers.3d"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

/// The editor: open folder, current photo, its edit and history, and everything the UI shows.
@Observable final class EditorModel {
    // Library
    var folder: URL?
    var items: [PhotoItem] = []
    var selection: Int?
    var marked: Set<Int> = []

    // Archive: edits are kept for the session in memory and saved only when asked ("Save", ⌘S).
    var archived: [ArchiveEntry] = Archive.shared.entries
    /// Photos whose edit differs from what was last saved.
    var unsaved: Set<URL> = []
    @ObservationIgnored private var sessionEdits: [URL: EditState] = [:]

    // Current photo
    private(set) var source: SourceImage?
    var edit = EditState() { didSet { editChanged(from: oldValue) } }
    private(set) var history: [HistoryEntry] = []
    private(set) var historyIndex = 0
    var loadingFullQuality = false
    var status: String?

    // View
    var tool: Tool = .none { didSet { toolChanged(oldValue) } }
    var showBefore = false { didSet { if showBefore != oldValue { requestRender() } } }
    var showHistogram = true
    var showClipping = false { didSet { canvas.setClipping(showClipping, matrix: simd_float3x3(histogramSpace.fromRec2020)) } }
    var histogram = Histogram.empty
    var category: InspectorCategory = .light { didSet { if category != oldValue { updateCanvasTools(); requestRender() } } }

    // Masks
    /// Selected mask and part (by id), and whether the selected mask is shown in red.
    var maskSelection: UUID? { didSet { if maskSelection != oldValue { updateCanvasTools(); requestRender() } } }
    var partSelection: UUID? { didSet { if partSelection != oldValue { updateCanvasTools() } } }
    var showMaskOverlay = false { didSet { if showMaskOverlay != oldValue { requestRender() } } }
    /// Brush tip: radius as a fraction of the long side, feather and flow 0…100, erase.
    var brushSize = 0.03
    var brushFeather = 60.0
    var brushFlow = 100.0
    var brushErase = false
    /// Pointer over the photo (image px) for the brush outline; nil when outside.
    var hoverPoint: CGPoint?
    /// A stroke or handle drag is in progress (the mask is shown while it lasts).
    var maskDragging = false { didSet { if maskDragging != oldValue { requestRender() } } }

    // Presets: the list, and the one previewed while the pointer is over it.
    var presets: [Preset] = PresetStore.shared.all
    var previewPreset: Preset? { didSet { if previewPreset != oldValue { requestRender() } } }

    // Layers (double exposure)
    var layerSelection: UUID? { didSet { if layerSelection != oldValue { updateCanvasTools() } } }
    /// Small pictures of the layers' photos, their sizes and orientations, and files that could not be found.
    var layerThumbs: [String: CGImage] = [:]
    @ObservationIgnored var layerFrames: [String: LayerMath.Frame] = [:]
    var missingLayers: Set<String> = []
    var layersLoading: Set<String> = []
    @ObservationIgnored let layerQueue = DispatchQueue(label: "positives.layers", qos: .userInitiated)
    var expanded: Set<String> = ["wb", "light", "presence", "color", "mixer", "targeted", "grading", "curves", "film", "grain", "bloom", "vignette",
                                 "masks", "maskParts", "maskAdjust", "recipe", "layers", "layer"]
    var mixerSelection = 0
    var mixerMode = 0                       // 0 = by colour, 1 = hue, 2 = saturation, 3 = luminance (all eight)
    var targetSelection: Int?
    /// Shows which pixels the selected targeted colour affects (everything else grey).
    var showTargetOverlay = false { didSet { if showTargetOverlay != oldValue { requestRender() } } }
    var curveChannel: ToneCurves.Channel = .master
    var selectedCurvePoint: Int?
    var gradingZone = 0                     // 0 shadows, 1 midtones, 2 highlights, 3 global
    var frameTime: Double = 0
    var exportMessage: String?
    var exportProgress: Double?

    /// Space for histogram and clipping warnings (the export space).
    var histogramSpace: OutputColorSpace = .sRGB

    let canvas = CanvasController()
    let canvasState = CanvasState()

    // Private state
    @ObservationIgnored let scheduler: RenderScheduler?
    @ObservationIgnored private let decodeQueue = DispatchQueue(label: "positives.decode", qos: .userInitiated)
    @ObservationIgnored private let thumbQueue = DispatchQueue(label: "positives.thumbs", qos: .utility)
    @ObservationIgnored private var viewport: Viewport?
    @ObservationIgnored private var version = 0
    @ObservationIgnored private var photoStartVersion = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var interaction: (label: String, before: EditState)?
    @ObservationIgnored private var suppressHistory = false
    @ObservationIgnored private var saveTimer: Timer?
    @ObservationIgnored private var fullCache: [URL: SourceImage] = [:]
    @ObservationIgnored private var cropDraft: CGRect?
    @ObservationIgnored var clipboard: EditState?
    /// Last frame shown (self-test and diagnostics).
    @ObservationIgnored private(set) var lastDelivered: (version: Int, exact: Bool) = (0, false)
    @ObservationIgnored var frameLog: [(time: Date, render: Double, exact: Bool)] = []
    var diagnostics: String {
        "version \(version), delivered \(lastDelivered), frames \(frameLog.count), viewport \(String(describing: viewport)), source \(source?.url.lastPathComponent ?? "-") proxy \(source?.isProxy ?? false), status \(status ?? "-")"
    }
    var isSettled: Bool { lastDelivered.version == version && lastDelivered.exact }

    init() {
        if let ctx = MetalContext.shared, let engine = try? RenderEngine(context: ctx) {
            scheduler = RenderScheduler(engine: engine)
        } else {
            scheduler = nil
            status = "This Mac's GPU could not be used"
        }
        scheduler?.onResult = { [weak self] in self?.handle($0) }
        MaskDetector.warmUp()
        canvas.onViewport = { [weak self] v in self?.viewport = v; self?.requestRender() }
        canvas.onClick = { [weak self] p in self?.canvasClicked(at: p) }
        canvas.onDraw = { [weak self] phase, p, mods in self?.canvasDraw(phase, at: p, modifiers: mods) }
        canvas.onHover = { [weak self] p in if self?.canvasDrawKind == .brush || self?.hoverPoint != nil { self?.hoverPoint = p } }
    }

    var current: PhotoItem? { selection.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    var hasPhoto: Bool { source != nil }
    var isRaw: Bool { source?.kind == .raw }

    // MARK: Opening

    func chooseAndOpen() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image, .folder]
        p.message = "Choose a folder or photos"
        if p.runModal() == .OK { open(p.urls) }
    }

    func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        var files: [URL] = []
        var dir = first.hasDirectoryPath ? first : first.deletingLastPathComponent()
        if urls.count == 1, (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            dir = first
            files = (try? FileManager.default.contentsOfDirectory(at: first, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        } else if urls.count == 1 {
            // A single photo: open its whole folder, starting at it.
            files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        } else {
            files = urls
        }
        files = files.filter { ImageLoader.isSupported($0) }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !files.isEmpty else { status = "No photos there"; return }
        rememberCurrent()
        folder = dir
        items = files.map(PhotoItem.init)
        marked = []
        fullCache = [:]
        let start = urls.count == 1 && !first.hasDirectoryPath ? (files.firstIndex(of: first.standardizedFileURL) ?? files.firstIndex { $0.lastPathComponent == first.lastPathComponent } ?? 0) : 0
        loadThumbnails()
        select(start)
    }

    private func loadThumbnails() {
        let list = items
        thumbQueue.async {
            for item in list {
                let t = ImageLoader.browsingThumbnail(url: item.url, maxPixel: 240)
                DispatchQueue.main.async { if item.thumbnail == nil { item.thumbnail = t } }
            }
        }
    }

    func select(_ index: Int) {
        guard items.indices.contains(index), index != selection || source == nil else { return }
        rememberCurrent()
        selection = index
        tool = .none
        showBefore = false
        let item = items[index]
        generation += 1
        let gen = generation
        histogram = .empty
        canvas.clear()
        if let cached = fullCache[item.url] {
            setSource(cached, upgrade: false)
            prefetch(after: index)
            return
        }
        status = "Opening \(item.url.lastPathComponent)…"
        let raw = ImageLoader.isRaw(item.url)
        decodeQueue.async { [weak self] in
            do {
                if raw {
                    let proxy = try SourceLoader.load(url: item.url, proxy: true)
                    DispatchQueue.main.async {
                        guard let self, gen == self.generation else { return }
                        self.setSource(proxy, upgrade: false)
                        self.loadingFullQuality = true
                    }
                }
                guard gen == self?.generation else { return }
                let full = try SourceLoader.load(url: item.url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cache(full)
                    guard gen == self.generation else { return }
                    self.setSource(full, upgrade: raw)
                    self.loadingFullQuality = false
                    self.prefetch(after: index)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, gen == self.generation else { return }
                    self.status = "Could not open \(item.url.lastPathComponent): \(error)"
                }
            }
        }
    }

    /// Decodes the next photo in the background so moving on is instant.
    private func prefetch(after index: Int) {
        guard items.indices.contains(index + 1) else { return }
        let url = items[index + 1].url
        guard fullCache[url] == nil else { return }
        let gen = generation
        decodeQueue.async { [weak self] in
            guard let self, gen == self.generation, let s = try? SourceLoader.load(url: url) else { return }
            DispatchQueue.main.async { self.cache(s) }
        }
    }

    private func cache(_ s: SourceImage) {
        fullCache[s.url] = s
        // Keep the current photo and its neighbours only (a 26 MP float image is ~400 MB).
        let keep = Set([selection.map { $0 - 1 }, selection, selection.map { $0 + 1 }].compactMap { $0 }.filter { items.indices.contains($0) }.map { items[$0].url })
        for k in fullCache.keys where !keep.contains(k) { fullCache[k] = nil }
    }

    private func setSource(_ s: SourceImage, upgrade: Bool) {
        source = s
        status = nil
        if !upgrade {
            suppressHistory = true
            edit = sessionEdits[s.url] ?? savedEdit(for: s.url) ?? .initial(for: s)
            suppressHistory = false
            history = [HistoryEntry(label: "Opened", state: edit)]
            historyIndex = 0
            photoStartVersion = version + 1
        }
        canvas.setImageSize(displaySize, refit: !upgrade)
        ensureLayerSources()
        requestRender()
    }

    func selectNext() { if let s = selection, s + 1 < items.count { select(s + 1) } }
    func selectPrevious() { if let s = selection, s > 0 { select(s - 1) } }

    func filmstripClicked(_ i: Int, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            if marked.contains(i) { marked.remove(i) } else { marked.insert(i) }
            if let s = selection { marked.insert(s) }
        } else if modifiers.contains(.shift), let s = selection {
            marked = Set(min(s, i)...max(s, i))
        } else {
            marked = []
            select(i)
        }
    }

    // MARK: Editing & history

    /// Changes the edit. Slider drags are grouped into one history step by `beginInteraction` / `endInteraction`.
    func change(_ label: String, _ body: (inout EditState) -> Void) {
        var e = edit
        body(&e)
        guard e != edit else { return }
        if interaction == nil {
            edit = e
            commit(label)
        } else {
            edit = e
        }
    }

    func beginInteraction(_ label: String) {
        interaction = (label, edit)
        requestRender()
    }

    func endInteraction() {
        guard let i = interaction else { return }
        interaction = nil
        if edit != i.before { commit(i.label) }
        requestRender()
    }

    var isInteracting: Bool { interaction != nil }

    private func commit(_ label: String) {
        guard !suppressHistory else { return }
        if historyIndex < history.count - 1 { history.removeSubrange((historyIndex + 1)...) }
        history.append(HistoryEntry(label: label, state: edit))
        historyIndex = history.count - 1
        scheduleSave()
    }

    var canUndo: Bool { historyIndex > 0 }
    var canRedo: Bool { historyIndex < history.count - 1 }

    func undo() { guard canUndo else { return }; jump(to: historyIndex - 1) }
    func redo() { guard canRedo else { return }; jump(to: historyIndex + 1) }

    func jump(to i: Int) {
        guard history.indices.contains(i) else { return }
        historyIndex = i
        suppressHistory = true
        edit = history[i].state
        suppressHistory = false
        scheduleSave()
    }

    private func editChanged(from old: EditState) {
        guard edit != old else { return }
        if edit.geometry != old.geometry, tool != .crop { canvas.setImageSize(displaySize, refit: false) }
        if edit.layers.map(\.path) != old.layers.map(\.path) { ensureLayerSources() }
        requestRender()
    }

    func resetAll() {
        guard let s = source else { return }
        var e = EditState.initial(for: s)
        e.geometry = edit.geometry
        change("Reset") { $0 = e }
    }

    func copySettings() { clipboard = edit }

    /// Pastes everything except crop / rotation (which belong to each frame).
    func pasteSettings() {
        guard let c = clipboard else { return }
        if marked.count > 1 { pasteToMarked(c); return }
        change("Paste settings") { e in
            let g = e.geometry
            e = c
            e.geometry = g
        }
    }

    // MARK: Presets

    /// Applies a preset to this photo, or to every selected photo when several are selected.
    func applyPreset(_ p: Preset) {
        previewPreset = nil
        guard marked.count > 1 else { change("Preset: \(p.name)") { $0 = $0.applying(p) }; return }
        for i in marked {
            let url = items[i].url
            if i == selection { change("Preset: \(p.name)") { $0 = $0.applying(p) }; continue }
            let e = storedEdit(for: url) ?? {
                var x = EditState()
                if let s = fullCache[url] { x = .initial(for: s) } else if let o = Self.orientation(of: url) { x.geometry = o }
                return x
            }()
            sessionEdits[url] = e.applying(p)
            unsaved.insert(url)
            items[i].edited = true
        }
        status = "\(p.name) applied to \(marked.count) photos"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.status?.hasSuffix("photos") == true { self?.status = nil } }
    }

    func savePreset(named name: String, scope: Preset.Scope = .look) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        PresetStore.shared.add(name: n, look: edit, scope: scope)
        presets = PresetStore.shared.all
    }

    func renamePreset(_ p: Preset, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !p.builtIn else { return }
        PresetStore.shared.rename(p.id, to: n)
        presets = PresetStore.shared.all
    }

    func deletePreset(_ p: Preset) {
        guard !p.builtIn else { return }
        PresetStore.shared.remove(p.id)
        presets = PresetStore.shared.all
    }

    private func pasteToMarked(_ c: EditState) {
        for i in marked {
            let url = items[i].url
            if i == selection {
                change("Paste settings") { e in let g = e.geometry; e = c; e.geometry = g }
                continue
            }
            var e = storedEdit(for: url) ?? {
                var x = EditState()
                if let s = fullCache[url] { x = .initial(for: s) } else if let o = Self.orientation(of: url) { x.geometry = o }
                return x
            }()
            let g = e.geometry
            e = c
            e.geometry = g
            sessionEdits[url] = e
            unsaved.insert(url)
            items[i].edited = true
        }
        status = nil
    }

    /// Upright geometry of a file without decoding it (EXIF / camera orientation).
    static func orientation(of url: URL) -> FrameGeometry? {
        let props = ImageLoader.properties(url: url)
        guard let o = props["Orientation"] as? Int else { return nil }
        let (t, f) = ImageLoader.orientation(o)
        return FrameGeometry(quarterTurns: t, flipHorizontal: f)
    }

    // MARK: Session edits and the archive

    /// What was last saved for a photo: its archive entry, or an edit saved next to it by an earlier version.
    func savedEdit(for url: URL) -> EditState? { Archive.shared.entry(for: url)?.edit }

    /// The photo's current edit in this session, or the saved one.
    func storedEdit(for url: URL) -> EditState? { sessionEdits[url] ?? savedEdit(for: url) }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in self?.rememberCurrent() }
    }

    /// Keeps the current photo's edit for the session (in memory) and notes whether it differs from the saved one.
    func rememberCurrent() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard let s = source, let item = current, item.url == s.url else { return }
        sessionEdits[s.url] = edit
        let saved = savedEdit(for: s.url) ?? .initial(for: s)
        if edit == saved { unsaved.remove(s.url) } else { unsaved.insert(s.url) }
        item.edited = edit != .initial(for: s) || Archive.shared.entry(for: s.url) != nil
    }

    var currentIsUnsaved: Bool { current.map { unsaved.contains($0.url) } ?? false }
    var currentIsArchived: Bool { current.map { u in archived.contains { $0.path == u.url.standardizedFileURL.path } } ?? false }

    /// Saves the current photo (or all marked ones) to the archive, with a thumbnail of the edit.
    func saveToArchive() {
        rememberCurrent()
        let chosen = marked.count > 1 ? marked.sorted().map { items[$0] } : (current.map { [$0] } ?? [])
        var count = 0
        for item in chosen {
            guard let e = storedEdit(for: item.url) ?? (item.url == source?.url ? edit : nil) else { continue }
            do {
                try Archive.shared.save(e, for: item.url, thumbnail: item.thumbnail)
                unsaved.remove(item.url)
                item.edited = true
                count += 1
            } catch {
                status = "Could not save: \(error.localizedDescription)"
                return
            }
        }
        archived = Archive.shared.entries
        status = count == 1 ? "Saved to the archive" : "Saved \(count) photos to the archive"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.status?.hasPrefix("Saved") == true { self?.status = nil }
        }
    }

    /// Saves every photo edited in this session (when quitting).
    func saveAllUnsaved() {
        rememberCurrent()
        for url in unsaved {
            guard let e = sessionEdits[url] else { continue }
            let thumb = items.first { $0.url == url }?.thumbnail
            try? Archive.shared.save(e, for: url, thumbnail: thumb)
        }
        unsaved = []
        archived = Archive.shared.entries
    }

    func removeFromArchive(_ e: ArchiveEntry) {
        Archive.shared.remove(e.id)
        archived = Archive.shared.entries
        if let i = items.firstIndex(where: { $0.url.standardizedFileURL.path == e.path }) {
            unsaved.insert(items[i].url)
        }
    }

    /// Opens an archived photo where it was left.
    func openArchived(_ e: ArchiveEntry) {
        guard let url = Archive.shared.resolve(e) else {
            status = "\(e.name) was moved or deleted — it can no longer be found"
            return
        }
        archived = Archive.shared.entries
        open([url])
    }

    /// Back to the start screen (edits stay in memory until the app quits).
    func goHome() {
        rememberCurrent()
        generation += 1
        tool = .none
        source = nil
        items = []
        selection = nil
        marked = []
        folder = nil
        fullCache = [:]
        history = []
        historyIndex = 0
        histogram = .empty
        status = nil
        canvas.clear()
        archived = Archive.shared.entries
    }

    // MARK: Rendering

    /// Size of what the canvas shows: the cropped picture, or the whole frame while cropping.
    var displaySize: CGSize {
        guard let s = source else { return .zero }
        let o = renderEdit.geometry.outputSize(sourceWidth: s.fullSize.width, sourceHeight: s.fullSize.height)
        return CGSize(width: o.width, height: o.height)
    }

    /// The edit as rendered: the "before" state when comparing, uncropped while cropping.
    var renderEdit: EditState {
        var e = edit
        if showBefore, let s = source {
            e = .initial(for: s)
            e.geometry = edit.geometry
        }
        if let p = previewPreset, !showBefore { e = e.applying(p) }
        if tool == .crop { e.geometry.crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
        return e
    }

    func requestRender() {
        guard let s = source, let scheduler, let vp = viewport else { return }
        version += 1
        scheduler.submit(.init(source: s, edit: renderEdit, viewport: vp, interacting: isInteracting,
                               interactiveGeometry: isInteracting && tool == .crop, version: version,
                               histogramSpace: histogramSpace, wantsThumbnail: !showBefore && tool == .none && !showTargetOverlay && previewPreset == nil,
                               overlayTarget: showTargetOverlay && !showBefore ? targetSelection : nil,
                               overlayMask: maskOverlayIndex))
    }

    private func handle(_ r: RenderScheduler.Result) {
        guard r.version >= photoStartVersion else { return }
        if let t = r.thumbnail { current?.thumbnail = t; return }
        canvas.show(main: r.main, overview: r.overview)
        lastDelivered = (r.version, r.exact)
        frameLog.append((Date(), r.frameTime, r.exact))
        if frameLog.count > 2000 { frameLog.removeFirst(1000) }
        if let h = r.histogram, h != histogram { histogram = h }
        if r.frameTime > 0 { frameTime = r.frameTime }
    }

    // MARK: Tools

    private func toolChanged(_ old: Tool) {
        guard tool != old else { return }
        canvas.setClickTool(tool == .whiteBalance || tool == .targetColor || tool == .curvePoint || tool == .maskColor)
        updateCanvasTools()
        canvas.setZoomEnabled(tool != .crop)
        if tool == .crop || old == .crop {
            canvas.setImageSize(displaySize, refit: true)
            requestRender()
        }
    }

    func toggleTool(_ t: Tool) { tool = tool == t ? .none : t }

    private func canvasClicked(at p: CGPoint) {
        switch tool {
        case .targetColor: pickTargetColor(at: p); return
        case .curvePoint: pickCurvePoint(at: p); return
        case .maskColor: pickMaskColor(at: p); return
        default: break
        }
        guard tool == .whiteBalance, let s = source, let scheduler else { return }
        let g = renderEdit.geometry
        scheduler.perform { [weak self] engine in
            guard let native = try? engine.sampleNative(at: p, geometry: g, radius: 4), let wb = s.whiteBalance(neutralizing: native) else { return }
            DispatchQueue.main.async {
                guard let self, self.source === s else { return }
                self.change("White balance picker") { $0.whiteBalance = wb }
            }
        }
    }

    /// Adds a targeted colour range centred on the colour under the pointer (as it is before targeted
    /// colours and grading are applied).
    func pickTargetColor(at p: CGPoint) {
        guard let scheduler, edit.targeted.count < TargetedColor.maximumCount else { tool = .none; return }
        var e = renderEdit
        e.targeted = []
        e.grading = ColorGrading()
        let s = source
        scheduler.perform { [weak self] engine in
            guard let rgb = try? engine.sampleDeveloped(e, at: p, radius: 3) else { return }
            let lch = ColorMath.lch(rgb)
            DispatchQueue.main.async {
                guard let self, self.source === s else { return }
                self.change("Pick colour") { $0.targeted.append(TargetedColor(hue: lch.hue, chroma: lch.chroma, lightness: lch.lightness)) }
                self.targetSelection = self.edit.targeted.count - 1
                self.tool = .none
            }
        }
    }

    /// Adds a point to the current curve at the tone under the pointer (its value at the input of the curves).
    func pickCurvePoint(at p: CGPoint) {
        guard let scheduler else { return }
        let e = renderEdit
        let channel = curveChannel
        let s = source
        scheduler.perform { [weak self] engine in
            guard let rgb = try? engine.sampleDeveloped(e, at: p, radius: 2, beforeCurves: true) else { return }
            let v: Float = channel == .master ? ToneMath.lum(rgb) : rgb[channel.rawValue - 1]
            let x = Double(min(max(ToneMath.toPerceptual(v), 0), 1))
            DispatchQueue.main.async {
                guard let self, self.source === s else { return }
                self.addCurvePoint(x: x, channel: channel)
            }
        }
    }

    /// Adds (or selects, if one is very close) a point on the curve at input x, keeping the curve's shape.
    func addCurvePoint(x: Double, channel: ToneCurves.Channel) {
        var pts = CurveMath.normalized(edit.curves[channel])
        if let near = pts.firstIndex(where: { abs($0.x - x) < 0.02 }) { selectedCurvePoint = near; return }
        let y = CurveMath.evaluate(pts, x)
        pts.append(CurvePoint(x, y))
        pts.sort { $0.x < $1.x }
        change("Curve point") { $0.curves[channel] = pts }
        selectedCurvePoint = pts.firstIndex { $0.x == x }
    }

    /// Chooses a film look (nil = digital). Choosing a film turns its grain on if there was none and uses the
    /// film's own grain.
    func setFilm(_ id: String?) {
        let name = id.flatMap { FilmLooks.shared.look($0)?.name } ?? "No film"
        change("Film: \(name)") { e in
            e.film.stock = id
            e.film.paper = nil
            if let id, let l = FilmLooks.shared.look(id), l.variants[e.film.variant] == nil { e.film.variant = 0 }
            if id != nil {
                if e.grain.amount == 0 { e.grain.amount = 100 }
                e.grain.preset = nil
            }
        }
    }

    // Film browser previews

    /// Small previews of the photo through each film look ("" = no film), for the film browser.
    var filmPreviews: [String: CGImage] = [:]
    var filmTab = 0
    @ObservationIgnored private var previewKey: (URL, EditState)?

    /// Rebuilds the previews when the photo or its edit (apart from film and grain) changed.
    func refreshFilmPreviews() {
        guard let s = source, let scheduler, !isInteracting else { return }
        var e = edit
        e.film = FilmSettings(); e.grain.amount = 0; e.effects = Effects()
        if let k = previewKey, k.0 == s.url, k.1 == e { return }
        previewKey = (s.url, e)
        let spectral = FilmLooks.shared.looks.filter(\.isSpectral)
        scheduler.perform { [weak self] engine in
            do {
                try engine.setSource(s)
                let full = engine.outputSize(e.geometry)
                let view = ViewRequest(region: CGRect(origin: .zero, size: full), scale: min(1, 360 / max(full.width, full.height)), exact: false)
                let base = try engine.snapshot(try engine.render(e, view: view, slot: 2), maxSize: 180)
                var tiles: [String: LinearImage] = ["": base]
                for l in spectral {
                    var f = e
                    f.film.stock = l.id
                    tiles[l.id] = try engine.snapshot(try engine.render(f, view: view, slot: 2), maxSize: 180)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let looks = FilmLooks.shared.looks.filter { !$0.isSpectral }
                    var made = [CGImage?](repeating: nil, count: looks.count)
                    DispatchQueue.concurrentPerform(iterations: looks.count) { i in
                        guard let t = FilmLooks.shared.table(looks[i], variant: 0) else { return }
                        let r = LookRender(key: looks[i].id, table: t, grainCurve: 0)
                        var img = base
                        for y in 0..<img.height { for x in 0..<img.width { img[x, y] = r.apply(ToneMath.lookInput(base[x, y])) } }
                        made[i] = img.makeCGImage()
                    }
                    var out: [String: CGImage] = [:]
                    for (k, v) in tiles { out[k] = v.makeCGImage() }
                    for (i, l) in looks.enumerated() { out[l.id] = made[i] }
                    DispatchQueue.main.async { self?.filmPreviews = out }
                }
            } catch {
                NSLog("Positives film previews failed: \(error)")
            }
        }
    }

    // Crop

    func rotate(clockwise: Bool) {
        change(clockwise ? "Rotate right" : "Rotate left") { e in
            e.geometry.quarterTurns = (e.geometry.quarterTurns + (clockwise ? 1 : 3)) % 4
            // The crop rectangle turns with the picture.
            let c = e.geometry.crop
            e.geometry.crop = clockwise ? CGRect(x: 1 - c.maxY, y: c.minX, width: c.height, height: c.width)
                                        : CGRect(x: c.minY, y: 1 - c.maxX, width: c.height, height: c.width)
        }
        if tool == .crop { canvas.setImageSize(displaySize, refit: true) }
    }

    func flip(horizontal: Bool) {
        change(horizontal ? "Flip horizontal" : "Flip vertical") { e in
            // Flips act on the sensor; in the oriented picture an odd number of quarter turns swaps the axes.
            let swap = e.geometry.quarterTurns % 2 == 1
            if horizontal != swap { e.geometry.flipHorizontal.toggle() } else { e.geometry.flipVertical.toggle() }
            let c = e.geometry.crop
            e.geometry.crop = horizontal ? CGRect(x: 1 - c.maxX, y: c.minY, width: c.width, height: c.height)
                                         : CGRect(x: c.minX, y: 1 - c.maxY, width: c.width, height: c.height)
        }
    }

    /// Aspect ratio (width / height) of the uncropped, oriented frame.
    var frameAspect: Double {
        guard let s = source else { return 1.5 }
        var g = edit.geometry
        g.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let o = g.outputSize(sourceWidth: s.fullSize.width, sourceHeight: s.fullSize.height)
        return Double(o.width) / Double(o.height)
    }

    func setStraighten(_ angle: Double) {
        change("Straighten") { e in
            e.geometry.straighten = angle
            e.geometry.crop = CropMath.constrain(e.geometry.crop, straighten: angle, frameAspect: frameAspect)
        }
    }

    func setCropAspect(_ a: CropAspect) {
        change("Crop ratio") { e in
            e.cropAspect = a
            if let r = a.ratio(original: frameAspect) {
                e.geometry.crop = CropMath.fit(e.geometry.crop, ratio: r, frameAspect: frameAspect, straighten: e.geometry.straighten)
            }
        }
    }

    func resetCrop() {
        change("Reset crop") { e in
            e.geometry.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
            e.geometry.straighten = 0
            e.cropAspect = .original
        }
    }

    // MARK: Zoom

    func fit() { canvas.fit() }
    func zoom(_ level: CGFloat) { canvas.zoom(to: level) }
    func toggleZoom() { canvas.toggleZoom() }
    func zoomIn() { canvas.zoomStep(2) }
    func zoomOut() { canvas.zoomStep(0.5) }

    // MARK: Export

    func export(items chosen: [PhotoItem], options: ExportOptions, output: OutputSettings = OutputSettings(), to folder: URL) {
        rememberCurrent()
        let jobs = chosen.map { ($0.url, $0.url == source?.url ? edit : storedEdit(for: $0.url), fullCache[$0.url]) }
        exportMessage = "Exporting…"
        exportProgress = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let ctx = MetalContext.shared, let engine = try? RenderEngine(context: ctx) else { return }
            var done: [PhotoExportResult] = []
            var failures = 0
            for (i, job) in jobs.enumerated() {
                DispatchQueue.main.async { self?.exportMessage = "Exporting \(job.0.lastPathComponent) (\(i + 1)/\(jobs.count))" }
                do {
                    let r = try PhotoExport.export(photo: job.0, edit: job.1, options: options, to: folder, engine: engine, source: job.2, output: output)
                    done.append(r)
                } catch {
                    failures += 1
                    NSLog("Export failed for \(job.0.path): \(error)")
                }
                engine.releaseAll()
                DispatchQueue.main.async { self?.exportProgress = Double(i + 1) / Double(jobs.count) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let clipped = done.map(\.report.clippedFraction).max() ?? 0
                var msg = failures == 0 ? "Exported \(done.count) to \(folder.lastPathComponent)" : "Exported \(done.count), \(failures) failed"
                if clipped > 0.001 { msg += String(format: " · %.1f%% of values outside %@", clipped * 100, options.space.displayName) }
                self.exportMessage = msg
                self.exportProgress = nil
                if let last = done.last { NSWorkspace.shared.activateFileViewerSelecting([last.url]) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if self.exportProgress == nil { self.exportMessage = nil } }
            }
        }
    }
}

/// Crop rectangle helpers (normalised to the straightened, uncropped frame).
enum CropMath {
    /// Shrinks `crop` about its centre until it lies inside the rotated picture (no empty corners).
    static func constrain(_ crop: CGRect, straighten: Double, frameAspect: Double) -> CGRect {
        guard straighten != 0 else { return crop }
        func inside(_ r: CGRect) -> Bool {
            // Canvas of aspect A (width A, height 1); canvas -> picture is a rotation by θ about the centre.
            let a = frameAspect, t = straighten * .pi / 180
            let c = SIMD2(a / 2, 0.5)
            for p in [SIMD2(r.minX * a, r.minY), SIMD2(r.maxX * a, r.minY), SIMD2(r.minX * a, r.maxY), SIMD2(r.maxX * a, r.maxY)] {
                let d = p - c
                let q = SIMD2(cos(t) * d.x - sin(t) * d.y, sin(t) * d.x + cos(t) * d.y) + c   // as FrameGeometry.outputToSource
                if q.x < -1e-9 || q.y < -1e-9 || q.x > a + 1e-9 || q.y > 1 + 1e-9 { return false }
            }
            return true
        }
        if inside(crop) { return crop }
        var lo = 0.0, hi = 1.0
        for _ in 0..<40 {
            let s = (lo + hi) / 2
            let r = CGRect(x: crop.midX - crop.width * s / 2, y: crop.midY - crop.height * s / 2, width: crop.width * s, height: crop.height * s)
            if inside(r) { lo = s } else { hi = s }
        }
        return CGRect(x: crop.midX - crop.width * lo / 2, y: crop.midY - crop.height * lo / 2, width: crop.width * lo, height: crop.height * lo)
    }

    /// The largest rectangle of `ratio` (long / short side, keeping the current crop's orientation) centred on the crop.
    static func fit(_ crop: CGRect, ratio: Double, frameAspect: Double, straighten: Double) -> CGRect {
        let landscape = crop.width * frameAspect >= crop.height
        let target = landscape ? ratio : 1 / ratio          // width / height in pixels
        // normalised width / height = target / frameAspect
        var w = crop.width, h = w * frameAspect / target
        if h > crop.height { h = crop.height; w = h * target / frameAspect }
        var r = CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return constrain(r, straighten: straighten, frameAspect: frameAspect)
    }
}
