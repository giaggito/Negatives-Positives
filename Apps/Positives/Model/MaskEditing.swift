import AppKit
import Foundation
import PositivesCore
import simd

/// Masks: adding and editing masks and their parts, painting, gradients, colour picking, and the mapping
/// between the canvas (image px of the edited picture) and mask coordinates (sensor / long side).
extension EditorModel {
    enum MaskPreset: String, CaseIterable, Identifiable {
        case brush, linear, radial, luminance, color, subject, people, sky
        var id: String { rawValue }
        var title: String {
            switch self {
            case .brush: return "Brush"
            case .linear: return "Linear gradient"
            case .radial: return "Radial gradient"
            case .luminance: return "Luminance range"
            case .color: return "Color range"
            case .subject: return "Subject"
            case .people: return "People"
            case .sky: return "Sky"
            }
        }
        var symbol: String { kind.symbol }
        var kind: MaskComponent.Kind { MaskComponent.Kind(rawValue: rawValue) ?? .color }
    }

    // MARK: Selection

    var selectedMaskIndex: Int? { maskSelection.flatMap { id in edit.masks.firstIndex { $0.id == id } } }
    /// The mask being edited: the selected mask on the Masks page, the selected layer's "where it shows" mask
    /// on the Layers page.
    var selectedMaskPath: WritableKeyPath<EditState, LocalAdjustment>? {
        if category == .layers { return selectedLayerIndex.map { \EditState.layers[$0].mask } }
        return selectedMaskIndex.map { \EditState.masks[$0] }
    }
    var selectedMask: LocalAdjustment? { selectedMaskPath.map { edit[keyPath: $0] } }
    var selectedPartIndex: Int? {
        guard let m = selectedMask, let id = partSelection else { return nil }
        return m.components.firstIndex { $0.id == id }
    }
    var selectedPart: MaskComponent? { selectedPartIndex.flatMap { i in selectedMask?.components[i] } }

    /// Index of the mask drawn in red, if any.
    var maskOverlayIndex: Int? {
        guard category == .masks, !showBefore, let i = selectedMaskIndex else { return nil }
        return showMaskOverlay || maskDragging ? i : nil
    }

    /// Brush painting / gradient dragging on the canvas while the Masks page shows a brush or gradient part.
    var canvasDrawKind: MaskComponent.Kind? {
        guard category == .masks || category == .layers, tool == .none, let k = selectedPart?.kind, [.brush, .linear, .radial].contains(k) else { return nil }
        return k
    }

    func updateCanvasTools() {
        canvas.setDrawTool(canvasDrawKind != nil || canvasMovesLayer, brush: canvasDrawKind == .brush)
    }

    // MARK: Coordinates

    private var sensor: (w: Int, h: Int, long: Double) {
        let s = source?.fullSize ?? (1, 1)
        return (s.0, s.1, Double(max(s.0, s.1)))
    }

    /// Image px (full-resolution output of the current geometry) -> mask coordinates.
    func maskPoint(_ p: CGPoint) -> MaskPoint {
        let s = sensor
        let a = renderEdit.geometry.outputToSource(sourceWidth: s.w, sourceHeight: s.h)
        let q = a.apply([Double(p.x), Double(p.y)]) / s.long
        return MaskPoint(q.x, q.y)
    }

    func imagePoint(_ m: MaskPoint) -> CGPoint {
        let s = sensor
        let a = renderEdit.geometry.outputToSource(sourceWidth: s.w, sourceHeight: s.h).inverse
        let q = a.apply([m.x * s.long, m.y * s.long])
        return CGPoint(x: q.x, y: q.y)
    }

    /// Length in mask units of `px` image pixels (output px are source px at full quality).
    func maskLength(_ px: Double) -> Double { px / sensor.long }

    // MARK: Editing

    func changeMask(_ label: String, _ body: (inout LocalAdjustment) -> Void) {
        guard let kp = selectedMaskPath else { return }
        change(label) { body(&$0[keyPath: kp]) }
    }

    func changePart(_ label: String, _ body: (inout MaskComponent) -> Void) {
        guard let kp = selectedMaskPath, let j = selectedPartIndex else { return }
        change(label) { body(&$0[keyPath: kp].components[j]) }
    }

    /// A new part of the given kind, placed sensibly in the current picture.
    func newPart(_ kind: MaskComponent.Kind) -> MaskComponent {
        var c = MaskComponent(kind: kind)
        let size = displaySize
        switch kind {
        case .linear:
            c.start = maskPoint(CGPoint(x: size.width / 2, y: size.height * 0.1))
            c.end = maskPoint(CGPoint(x: size.width / 2, y: size.height * 0.5))
        case .radial:
            c.center = maskPoint(CGPoint(x: size.width / 2, y: size.height / 2))
            c.radiusX = maskLength(Double(min(size.width, size.height)) * 0.3)
            c.radiusY = c.radiusX * 0.8
            // Keep the ellipse level on screen whatever the photo's rotation.
            c.angle = -Double(renderEdit.geometry.quarterTurns % 4) * 90 - renderEdit.geometry.straighten
        default:
            break
        }
        return c
    }

    func addMask(_ preset: MaskPreset) {
        guard edit.masks.count < LocalAdjustment.maximumCount else { status = "Up to \(LocalAdjustment.maximumCount) masks per photo"; return }
        let part = newPart(preset.kind)
        let m = LocalAdjustment(name: uniqueMaskName(preset.title), components: [part])
        change("Add mask: \(preset.title)") { $0.masks.append(m) }
        category = .masks
        maskSelection = m.id
        partSelection = part.id
        if preset == .color { tool = .maskColor }
        if preset.kind.isDetected {
            status = "Finding \(preset == .subject ? "the subject" : (preset == .people ? "people" : "the sky"))…"
            clearStatusSoon()
        }
    }

    func addPart(_ kind: MaskComponent.Kind, mode: MaskComponent.Mode) {
        guard let kp = selectedMaskPath else { return }
        let total = category == .layers ? edit.layers.reduce(0) { $0 + $1.mask.components.count } : edit.masks.reduce(0) { $0 + $1.components.count }
        guard total < LocalAdjustment.maximumComponents else { status = "Too many mask parts"; return }
        var part = newPart(kind)
        part.mode = edit[keyPath: kp].components.isEmpty ? .add : mode
        let verb = mode == .add ? "Add" : (mode == .subtract ? "Subtract" : "Intersect")
        change("\(verb) \(kind.title.lowercased())") { $0[keyPath: kp].components.append(part) }
        partSelection = part.id
        if kind == .color { tool = .maskColor }
    }

    func removeMask(_ id: UUID) {
        change("Delete mask") { $0.masks.removeAll { $0.id == id } }
        if maskSelection == id { maskSelection = edit.masks.last?.id; partSelection = selectedMask?.components.first?.id }
    }

    func duplicateMask(_ id: UUID) {
        guard let m = edit.masks.first(where: { $0.id == id }), edit.masks.count < LocalAdjustment.maximumCount else { return }
        var copy = m
        copy.id = UUID()
        copy.name = uniqueMaskName(m.name)
        copy.components = m.components.map { var c = $0; c.id = UUID(); return c }
        change("Duplicate mask") { $0.masks.append(copy) }
        maskSelection = copy.id
        partSelection = copy.components.first?.id
    }

    func removePart(_ id: UUID) {
        guard let kp = selectedMaskPath else { return }
        change("Delete mask part") { e in
            e[keyPath: kp].components.removeAll { $0.id == id }
            if let f = e[keyPath: kp].components.first, f.mode != .add { e[keyPath: kp].components[0].mode = .add }
        }
        if partSelection == id { partSelection = selectedMask?.components.last?.id }
    }

    func selectMask(_ id: UUID) {
        maskSelection = id
        partSelection = selectedMask?.components.first?.id
    }

    private func uniqueMaskName(_ base: String) -> String {
        let names = Set(edit.masks.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    func clearStatusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.status?.hasPrefix("Finding") == true { self?.status = nil }
        }
    }

    // MARK: Brush and gradients on the canvas

    private static var dragStart: (point: MaskPoint, part: MaskComponent)?

    /// Canvas drag in draw mode (image px). Brush: paints (⌥ erases); gradients: drawn from where the
    /// drag starts to where it ends.
    func canvasDraw(_ phase: CanvasDrawPhase, at p: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let kind = canvasDrawKind else {
            if canvasMovesLayer || phase == .ended { canvasMoveLayer(phase, at: p) }
            return
        }
        let m = maskPoint(p)
        switch phase {
        case .began:
            maskDragging = true
            beginInteraction(kind == .brush ? ((brushErase || modifiers.contains(.option)) ? "Erase" : "Brush") : "Draw gradient")
            guard let part = selectedPart else { return }
            Self.dragStart = (m, part)
            if kind == .brush {
                let stroke = BrushStroke(points: [m], radius: brushSize, feather: brushFeather, flow: brushFlow,
                                         erase: brushErase || modifiers.contains(.option))
                changePart("Brush") { $0.strokes.append(stroke) }
            }
        case .changed:
            guard let start = Self.dragStart else { return }
            if kind == .brush {
                changePart("Brush") { c in
                    guard var s = c.strokes.popLast() else { return }
                    let last = s.points.last!
                    // Points closer than a fifth of the tip add nothing visible.
                    if hypot(m.x - last.x, m.y - last.y) > s.radius * 0.2 { s.points.append(m) }
                    c.strokes.append(s)
                }
            } else if kind == .linear {
                changePart("Draw gradient") { $0.start = start.point; $0.end = m }
            } else {
                let r = hypot(m.x - start.point.x, m.y - start.point.y)
                guard r > 1e-4 else { return }
                let ratio = start.part.radiusY / max(start.part.radiusX, 1e-6)
                changePart("Draw gradient") { $0.center = start.point; $0.radiusX = r; $0.radiusY = r * ratio }
            }
        case .ended:
            Self.dragStart = nil
            endInteraction()
            maskDragging = false
        }
    }

    // MARK: Colour range picking

    func pickMaskColor(at p: CGPoint) {
        guard let scheduler, let s = source else { tool = .none; return }
        let g = renderEdit.geometry
        let params = DevelopParameters.resolve(renderEdit, source: s)
        scheduler.perform { [weak self] engine in
            guard let native = try? engine.sampleNative(at: p, geometry: g, radius: 3) else { return }
            let lab = Develop.maskLab(SIMD3<Float>(native), params)
            DispatchQueue.main.async {
                guard let self, self.source === s else { return }
                var h = Double(atan2(lab.z, lab.y)) * 180 / .pi
                if h < 0 { h += 360 }
                self.changePart("Pick color") { c in
                    c.hue = h; c.chroma = Double(simd_length(SIMD2(lab.y, lab.z))); c.lightness = Double(lab.x)
                }
                self.tool = .none
            }
        }
    }

}

enum CanvasDrawPhase { case began, changed, ended }
