import DarkroomUI
import PositivesCore
import simd
import SwiftUI

/// Masks category: the list of masks, the selected mask's parts (add / subtract / intersect, invert) and the
/// tools for the selected part, then the mask's own adjustments.
struct MaskPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        InspectorSection(title: "Masks", icon: "theatermask.and.paintbrush", isEnabled: PanelKit(model: model).enabled(\.masks, "Masks"),
                         isExpanded: PanelKit(model: model).expanded("masks"), isModified: !model.edit.masks.isEmpty,
                         onReset: { model.change("Delete all masks") { $0.masks = [] }; model.maskSelection = nil }) {
            VStack(alignment: .leading, spacing: 8) {
                if model.edit.masks.isEmpty {
                    Text("A mask applies its own adjustments to part of the photo. Add one to start.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.edit.masks) { m in MaskRow(model: model, mask: m) }
                addMenu
            }
        }
        if let mask = model.selectedMask {
            MaskPartsSection(model: model, mask: mask)
            MaskAdjustmentsSection(model: model, mask: mask)
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(EditorModel.MaskPreset.allCases) { p in
                Button { model.addMask(p) } label: { Label(p.title, systemImage: p.symbol) }
                if p == .color { Divider() }
            }
        } label: {
            Label("Add mask", systemImage: "plus").font(Theme.label)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(Theme.secondary)
        .fixedSize()
        .disabled(model.edit.masks.count >= LocalAdjustment.maximumCount)
    }
}

private struct MaskRow: View {
    @Bindable var model: EditorModel
    let mask: LocalAdjustment
    @State private var renaming = false
    @State private var name = ""

    var body: some View {
        let selected = model.maskSelection == mask.id
        HStack(spacing: 8) {
            Image(systemName: mask.components.first.map { $0.kind.symbol } ?? "circle.dashed")
                .font(.system(size: 11)).frame(width: 16)
                .foregroundStyle(selected ? Color.black : Theme.secondary)
            if renaming {
                TextField("", text: $name, onCommit: {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    if !n.isEmpty, let i = model.edit.masks.firstIndex(where: { $0.id == mask.id }) { model.change("Rename mask") { $0.masks[i].name = n } }
                    renaming = false
                })
                .textFieldStyle(.plain).font(Theme.label)
            } else {
                Text(mask.name).font(Theme.label).foregroundStyle(selected ? Color.black : (mask.enabled ? Theme.text : Theme.tertiary)).lineLimit(1)
            }
            Spacer()
            Button {
                if let i = model.edit.masks.firstIndex(where: { $0.id == mask.id }) {
                    model.change(mask.enabled ? "Hide mask" : "Show mask") { $0.masks[i].enabled.toggle() }
                }
            } label: {
                Image(systemName: mask.enabled ? "eye" : "eye.slash").font(.system(size: 11))
                    .foregroundStyle(selected ? Color.black.opacity(0.7) : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help(mask.enabled ? "Turn this mask off" : "Turn this mask on")
        }
        .padding(.horizontal, 8).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent : Theme.hairline.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { name = mask.name; renaming = true }
        .onTapGesture { model.selectMask(mask.id) }
        .contextMenu {
            Button("Rename") { name = mask.name; renaming = true }
            Button("Duplicate") { model.duplicateMask(mask.id) }
            Button(mask.invert ? "Don't Invert" : "Invert") {
                if let i = model.edit.masks.firstIndex(where: { $0.id == mask.id }) { model.change("Invert mask") { $0.masks[i].invert.toggle() } }
            }
            Divider()
            Button("Delete") { model.removeMask(mask.id) }
        }
    }
}

/// The parts of the selected mask (or of a layer's "where it shows" mask) and the tool of the selected part.
struct MaskPartsSection: View {
    @Bindable var model: EditorModel
    let mask: LocalAdjustment
    var forLayer = false

    var body: some View {
        InspectorSection(title: mask.name, icon: "square.on.circle", isEnabled: Binding(
            get: { mask.enabled },
            set: { v in model.changeMask(v ? "Show mask" : "Hide mask") { $0.enabled = v } }),
                         isExpanded: PanelKit(model: model).expanded("maskParts"), isModified: forLayer && !mask.components.isEmpty,
                         onReset: forLayer ? { model.changeMask("Show layer everywhere") { $0.components = []; $0.invert = false } } : nil) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if forLayer && mask.components.isEmpty {
                    Text("Everywhere. Add a part to choose where the layer shows — Subject to fill a silhouette, Sky to put it in the sky, a gradient to fade it out.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 4) {
                    ForEach(Array(mask.components.enumerated()), id: \.element.id) { i, c in partRow(c, first: i == 0) }
                }
                HStack(spacing: 6) {
                    partMenu("Add", .add, "plus")
                    partMenu("Subtract", .subtract, "minus")
                    partMenu("Intersect", .intersect, "circle.circle")
                }
                Divider().overlay(Theme.hairline)
                if let part = model.selectedPart { tools(part) }
                HStack(spacing: 14) {
                    if !forLayer {
                        Toggle("Show overlay", isOn: $model.showMaskOverlay).toggleStyle(.checkbox).font(Theme.label)
                            .help("Show the selected mask in red (O)")
                    }
                    Toggle("Invert mask", isOn: Binding(get: { mask.invert }, set: { v in model.changeMask("Invert mask") { $0.invert = v } }))
                        .toggleStyle(.checkbox).font(Theme.label)
                }
                .foregroundStyle(Theme.secondary)
            }
        }
    }

    private func partRow(_ c: MaskComponent, first: Bool) -> some View {
        let selected = model.partSelection == c.id
        return HStack(spacing: 8) {
            Text(first ? "" : (c.mode == .add ? "+" : (c.mode == .subtract ? "−" : "∩")))
                .font(.system(size: 12, weight: .semibold, design: .rounded)).frame(width: 12)
                .foregroundStyle(selected ? Color.black.opacity(0.7) : Theme.tertiary)
            Image(systemName: c.kind.symbol).font(.system(size: 11)).frame(width: 16)
            Text(c.kind.title + (c.invert ? " (inverted)" : "")).font(Theme.label).lineLimit(1)
            Spacer()
            Button { if let j = mask.components.firstIndex(where: { $0.id == c.id }) {
                model.changeMask("Invert part") { $0.components[j].invert.toggle() } } } label: {
                Image(systemName: "circle.lefthalf.filled.inverse").font(.system(size: 11))
            }
            .buttonStyle(.plain).help("Invert this part")
            Button { model.removePart(c.id) } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                .buttonStyle(.plain).help("Delete this part")
        }
        .foregroundStyle(selected ? Color.black : Theme.secondary)
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent.opacity(0.9) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.hairline))
        .contentShape(Rectangle())
        .onTapGesture { model.partSelection = c.id }
    }

    private func partMenu(_ title: String, _ mode: MaskComponent.Mode, _ symbol: String) -> some View {
        Menu {
            ForEach(MaskComponent.Kind.allCases, id: \.self) { k in
                Button { model.addPart(k, mode: mode) } label: { Label(k.title, systemImage: k.symbol) }
            }
        } label: {
            Label(title, systemImage: symbol).font(.system(size: 11))
        }
        .menuStyle(.button).buttonStyle(.plain).foregroundStyle(Theme.secondary).fixedSize()
        .help(mode == .add ? "Add an area to the mask" : (mode == .subtract ? "Remove an area from the mask" : "Keep only where both overlap"))
    }

    @ViewBuilder
    private func tools(_ part: MaskComponent) -> some View {
        let kit = PanelKit(model: model)
        switch part.kind {
        case .brush:
            Segmented(options: ["Paint", "Erase"], selection: Binding(get: { model.brushErase ? 1 : 0 }, set: { model.brushErase = $0 == 1 }))
            ParameterSlider(title: "Size", value: Binding(get: { model.brushSize * 1000 }, set: { model.brushSize = $0 / 1000 }),
                            range: 2...200, defaultValue: 30, format: { String(format: "%.0f", $0) })
            ParameterSlider(title: "Feather", value: $model.brushFeather, range: 0...100, defaultValue: 60, format: { String(format: "%.0f", $0) })
            ParameterSlider(title: "Flow", value: $model.brushFlow, range: 1...100, defaultValue: 100, format: { String(format: "%.0f", $0) })
            Text("Paint on the photo. Hold ⌥ to erase. Pinch or scroll to zoom in for detail.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            if !part.strokes.isEmpty {
                PlainTextButton(title: "Clear strokes", symbol: "trash") { model.changePart("Clear brush") { $0.strokes = [] } }
            }
        case .linear:
            Text("Drag on the photo to draw the gradient: fully applied where you start, fading to nothing where you stop. Drag the handles to adjust.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        case .radial:
            partSlider("Feather", \.feather, 0...100, 50, kit)
            Text("Drag on the photo from the centre outwards to draw it, or drag its handles.")
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        case .luminance:
            partSlider("Darkest", \.low, 0...100, 60, kit)
            partSlider("Brightest", \.high, 0...100, 100, kit)
            partSlider("Smoothness", \.smoothness, 0...50, 25, kit)
        case .color:
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(swatch(part)).frame(width: 34, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
                PlainTextButton(title: model.tool == .maskColor ? "Click the photo…" : "Pick color", symbol: "eyedropper") {
                    model.toggleTool(.maskColor)
                }
            }
            partSlider("Range", \.range, 5...90, 30, kit)
        case .subject, .people, .sky:
            Text(part.kind == .subject ? "The main subject, found automatically."
                 : (part.kind == .people ? "People, found automatically." : "The sky, found by a neural network and fitted to the photo's edges."))
                .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
        }
    }

    private func partSlider(_ title: String, _ kp: WritableKeyPath<MaskComponent, Double>, _ range: ClosedRange<Double>, _ def: Double,
                            _ kit: PanelKit) -> some View {
        ParameterSlider(title: title, value: Binding(get: { model.selectedPart?[keyPath: kp] ?? def },
                                                     set: { v in model.changePart(title) { $0[keyPath: kp] = v.rounded() } }),
                        range: range, defaultValue: def, format: { String(format: "%.0f", $0) }, onEditingChanged: kit.editing(title))
    }

    private func swatch(_ c: MaskComponent) -> Color {
        let h = c.hue * .pi / 180
        let rgb = ToneMath.rec2020ToSRGB * ToneMath.fromOklab(SIMD3(Float(c.lightness), Float(c.chroma * cos(h)), Float(c.chroma * sin(h))))
        func e(_ v: Float) -> Double { Double(ToneMath.srgbEncode(min(max(v, 0), 1))) }
        return Color(red: e(rgb.x), green: e(rgb.y), blue: e(rgb.z))
    }
}

/// The selected mask's adjustments.
private struct MaskAdjustmentsSection: View {
    @Bindable var model: EditorModel
    let mask: LocalAdjustment

    var body: some View {
        InspectorSection(title: "Adjustments", icon: "slider.horizontal.3", isEnabled: .constant(true), isExpanded: PanelKit(model: model).expanded("maskAdjust"),
                         isModified: !mask.settings.isNeutral,
                         onReset: { model.changeMask("Reset mask adjustments") { $0.settings = LocalSettings() } }, showsToggle: false) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                slider("Exposure", \.exposure, -4...4, step: 0.01, format: { String(format: "%+.2f EV", $0) })
                slider("Contrast", \.contrast)
                slider("Highlights", \.highlights)
                slider("Shadows", \.shadows)
                slider("Clarity", \.clarity)
                slider("Dehaze", \.dehaze)
                slider("Temperature", \.temperature, gradient: [Color(red: 0.4, green: 0.6, blue: 1), Color(white: 0.8), Color(red: 1, green: 0.8, blue: 0.35)])
                slider("Tint", \.tint, gradient: [Color(red: 0.4, green: 0.8, blue: 0.45), Color(white: 0.8), Color(red: 0.9, green: 0.45, blue: 0.85)])
                slider("Saturation", \.saturation, gradient: [Color(white: 0.5), Color(red: 0.95, green: 0.4, blue: 0.3)])
                slider("Color", \.colorAmount, 0...100, format: { String(format: "%.0f", $0) })
                if mask.settings.colorAmount > 0 {
                    slider("Hue", \.colorHue, 0...360, defaultValue: 40, format: { String(format: "%.0f°", $0) },
                           gradient: stride(from: 0.0, through: 360, by: 45).map { Color(hue: (($0 + 30).truncatingRemainder(dividingBy: 360)) / 360, saturation: 0.6, brightness: 0.9) })
                }
                slider("Grain", \.grain)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Curve").font(Theme.label).foregroundStyle(Theme.secondary)
                        Spacer()
                        if !mask.settings.curveIsIdentity {
                            PlainTextButton(title: "Reset", symbol: "arrow.uturn.backward") {
                                model.changeMask("Reset mask curve") { $0.settings.curve = LocalSettings().curve }
                            }
                        }
                    }
                    MaskCurve(model: model, points: mask.settings.curve)
                        .frame(height: 150)
                }
            }
        }
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<LocalSettings, Double>, _ range: ClosedRange<Double> = -100...100,
                        defaultValue: Double = 0, step: Double = 1, format: @escaping (Double) -> String = { String(format: "%+.0f", $0) },
                        gradient: [Color]? = nil) -> some View {
        let kit = PanelKit(model: model)
        return ParameterSlider(title: title, value: Binding(get: { model.selectedMask?.settings[keyPath: kp] ?? defaultValue },
                                                            set: { v in model.changeMask("Mask \(title.lowercased())") { $0.settings[keyPath: kp] = (v / step).rounded() * step } }),
                               range: range, defaultValue: defaultValue, format: format, centreMark: range.lowerBound < 0, gradient: gradient,
                               onEditingChanged: kit.editing("Mask \(title.lowercased())"))
    }
}

/// The mask's tone curve, edited like the global one.
private struct MaskCurve: View {
    @Bindable var model: EditorModel
    let points: [CurvePoint]
    @State private var selection: Int?

    var body: some View {
        CurveEditor(points: points, channel: .master, histogram: model.histogram.bins, selection: $selection,
                    onBegin: { model.beginInteraction("Mask curve") },
                    onChange: { pts in model.changeMask("Mask curve") { $0.settings.curve = pts } },
                    onEnd: { model.endInteraction() },
                    onRemove: { i in
                        guard points.count > 2, i > 0, i < points.count - 1 else { return }
                        model.changeMask("Remove curve point") { $0.settings.curve.remove(at: i) }
                    })
    }
}
