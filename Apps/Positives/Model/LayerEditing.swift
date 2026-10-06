import AppKit
import Foundation
import PositivesCore

/// Layers (double exposure): adding photos over the current one, loading them for the engine, moving and
/// placing them.
extension EditorModel {
    var selectedLayerIndex: Int? { layerSelection.flatMap { id in edit.layers.firstIndex { $0.id == id } } }
    var selectedLayer: PhotoLayer? { selectedLayerIndex.map { edit.layers[$0] } }

    private var sensorSize: (width: Int, height: Int) { (source?.fullSize.width ?? 1, source?.fullSize.height ?? 1) }

    func changeLayer(_ label: String, _ body: (inout PhotoLayer) -> Void) {
        guard let i = selectedLayerIndex else { return }
        change(label) { body(&$0.layers[i]) }
    }

    func selectLayer(_ id: UUID) {
        layerSelection = id
        partSelection = nil
    }

    // MARK: Adding and removing

    func chooseLayerPhoto() {
        guard source != nil, edit.layers.count < PhotoLayer.maximumCount else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [.image]
        p.message = "Choose a photo to lay over this one"
        p.directoryURL = source?.url.deletingLastPathComponent()
        if p.runModal() == .OK, let url = p.url { addLayer(url) }
    }

    /// Adds a photo as a new layer, covering the frame, once its quick version is loaded.
    func addLayer(_ url: URL) {
        guard let s = source, edit.layers.count < PhotoLayer.maximumCount else { return }
        status = "Adding \(url.lastPathComponent)…"
        loadLayer(url.path, proxyFirst: true) { [weak self] frame in
            guard let self, self.source === s else { return }
            if self.status?.hasPrefix("Adding") == true { self.status = nil }
            guard let frame else { self.status = "Could not open \(url.lastPathComponent)"; return }
            var l = LayerMath.place(PhotoLayer(path: url.path), frame: frame, photoSensor: self.sensorSize, geometry: self.edit.geometry)
            l.mask.name = "Where it shows"
            self.change("Add layer") { $0.layers.append(l) }
            self.category = .layers
            self.selectLayer(l.id)
        }
    }

    func removeLayer(_ id: UUID) {
        change("Delete layer") { $0.layers.removeAll { $0.id == id } }
        if layerSelection == id { layerSelection = edit.layers.last?.id }
    }

    func moveLayer(_ id: UUID, by offset: Int) {
        guard let i = edit.layers.firstIndex(where: { $0.id == id }), edit.layers.indices.contains(i + offset) else { return }
        change(offset > 0 ? "Move layer up" : "Move layer down") { $0.layers.swapAt(i, i + offset) }
    }

    // MARK: Placement

    /// Covers the frame (`fill`) or fits inside it, upright and centred, keeping blend and colour settings.
    func placeSelectedLayer(fill: Bool) {
        guard let l = selectedLayer, let frame = layerFrames[l.path] else { return }
        changeLayer(fill ? "Fill frame" : "Fit inside") {
            $0 = LayerMath.place($0, frame: frame, photoSensor: sensorSize, geometry: edit.geometry, fill: fill)
        }
    }

    var selectedLayerScreenAngle: Double {
        guard let l = selectedLayer else { return 0 }
        return LayerMath.screenAngle(l, geometry: edit.geometry, photoSensor: sensorSize)
    }

    func setSelectedLayerScreenAngle(_ a: Double) {
        let g = edit.geometry, s = sensorSize
        changeLayer("Rotate layer") { $0.angle = LayerMath.sensorAngle(screen: a, geometry: g, photoSensor: s) }
    }

    /// The layer's corners on the photo (image px of the edited picture), for its outline.
    func layerCorners(_ l: PhotoLayer) -> [CGPoint]? {
        guard let f = layerFrames[l.path] else { return nil }
        let up = f.upright
        let Ll = Double(max(up.width, up.height))
        let hx = Double(up.width) / Ll / 2, hy = Double(up.height) / Ll / 2
        let a = l.angle * .pi / 180
        return [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)].map { q in
            let x = (l.flip ? -q.0 : q.0) * l.size, y = q.1 * l.size
            return imagePoint(MaskPoint(l.center.x + x * cos(a) - y * sin(a), l.center.y + x * sin(a) + y * cos(a)))
        }
    }

    /// Dragging on the photo moves the selected layer (when no brush or gradient part is being drawn).
    var canvasMovesLayer: Bool { category == .layers && tool == .none && selectedLayerIndex != nil && canvasDrawKind == nil }

    private static var moveStart: (point: MaskPoint, center: MaskPoint)?

    func canvasMoveLayer(_ phase: CanvasDrawPhase, at p: CGPoint) {
        let m = maskPoint(p)
        switch phase {
        case .began:
            guard let l = selectedLayer else { return }
            Self.moveStart = (m, l.center)
            beginInteraction("Move layer")
        case .changed:
            guard let s = Self.moveStart else { return }
            changeLayer("Move layer") { $0.center = MaskPoint(s.center.x + m.x - s.point.x, s.center.y + m.y - s.point.y) }
        case .ended:
            Self.moveStart = nil
            endInteraction()
        }
    }

    // MARK: Loading

    /// Makes sure the engine has every layer photo of the current edit (quick version first for RAW files).
    func ensureLayerSources() {
        guard let scheduler else { return }
        let paths = Array(Set(edit.layers.map(\.path)))
        guard !paths.isEmpty else { return }
        scheduler.perform { [weak self] engine in
            let missing = paths.filter { !engine.hasLayerSource($0, full: true) }
            let noQuick = Set(missing.filter { !engine.hasLayerSource($0) })
            DispatchQueue.main.async {
                guard let self else { return }
                for p in missing where !self.layersLoading.contains(p) { self.loadLayer(p, proxyFirst: noQuick.contains(p)) }
            }
        }
    }

    /// Loads a layer photo (quick version, then full quality) into the engine. `ready` is called on the main
    /// thread once the first version is in (nil if the file cannot be opened).
    func loadLayer(_ path: String, proxyFirst: Bool, ready: ((LayerMath.Frame?) -> Void)? = nil) {
        guard let scheduler else { ready?(nil); return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            missingLayers.insert(path)
            ready?(nil)
            return
        }
        missingLayers.remove(path)
        layersLoading.insert(path)
        if layerThumbs[path] == nil {
            layerQueue.async { [weak self] in
                let t = ImageLoader.browsingThumbnail(url: url, maxPixel: 160)
                DispatchQueue.main.async { if let t { self?.layerThumbs[path] = t } }
            }
        }
        layerQueue.async { [weak self] in
            var first = true
            func deliver(_ s: SourceImage, last: Bool) {
                let frame = LayerMath.Frame(s)
                scheduler.perform { engine in
                    try? engine.setLayerSource(s)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.layerFrames[path] = frame
                        if last { self.layersLoading.remove(path) }
                        if first { first = false; ready?(frame) }
                        self.requestRender()
                    }
                }
            }
            if proxyFirst, ImageLoader.isRaw(url), let quick = try? SourceLoader.load(url: url, proxy: true) {
                deliver(quick, last: false)
            }
            if let full = try? SourceLoader.load(url: url) {
                deliver(full, last: true)
            } else {
                DispatchQueue.main.async {
                    self?.layersLoading.remove(path)
                    self?.missingLayers.insert(path)
                    if first { first = false; ready?(nil) }
                }
            }
        }
    }
}
