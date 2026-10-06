import DarkroomUI
import PositivesCore
import SwiftUI

/// Layers category: photos laid over this one (double exposure) — the list, then the selected layer's blend,
/// light, placement, and where it shows.
struct LayerPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        let kit = PanelKit(model: model)
        InspectorSection(title: "Layers", icon: "square.2.layers.3d", isEnabled: kit.enabled(\.layers, "Layers"),
                         isExpanded: kit.expanded("layers"), isModified: !model.edit.layers.isEmpty,
                         onReset: { model.change("Delete all layers") { $0.layers = [] }; model.layerSelection = nil }) {
            VStack(alignment: .leading, spacing: 8) {
                if model.edit.layers.isEmpty {
                    Text("Lay another photo over this one, like a double exposure on film. Film, grain and every adjustment then apply to both together.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(model.edit.layers.reversed()) { l in LayerRow(model: model, layer: l) }
                PlainTextButton(title: "Add photo…", symbol: "plus") { model.chooseLayerPhoto() }
                    .disabled(model.edit.layers.count >= PhotoLayer.maximumCount)
                    .help("Choose a photo to lay over this one (up to \(PhotoLayer.maximumCount))")
            }
        }
        if let layer = model.selectedLayer {
            LayerSettingsSection(model: model, layer: layer)
            MaskPartsSection(model: model, mask: layer.mask, forLayer: true)
        }
    }
}

private struct LayerRow: View {
    @Bindable var model: EditorModel
    let layer: PhotoLayer

    var body: some View {
        let selected = model.layerSelection == layer.id
        let missing = model.missingLayers.contains(layer.path)
        HStack(spacing: 8) {
            Group {
                if let t = model.layerThumbs[layer.path] {
                    Image(decorative: t, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Theme.hairline)
                }
            }
            .frame(width: 30, height: 22).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).font(Theme.label).lineLimit(1)
                    .foregroundStyle(selected ? Color.black : (layer.enabled ? Theme.text : Theme.tertiary))
                Text(missing ? "File not found" : (model.layersLoading.contains(layer.path) ? "Loading…" : "\(layer.blend.title) · \(Int(layer.amount))%"))
                    .font(.system(size: 10)).lineLimit(1)
                    .foregroundStyle(missing ? Color.red.opacity(0.8) : (selected ? Color.black.opacity(0.6) : Theme.tertiary))
            }
            Spacer()
            Button { if let i = model.edit.layers.firstIndex(where: { $0.id == layer.id }) {
                model.change(layer.enabled ? "Hide layer" : "Show layer") { $0.layers[i].enabled.toggle() } } } label: {
                Image(systemName: layer.enabled ? "eye" : "eye.slash").font(.system(size: 11))
                    .foregroundStyle(selected ? Color.black.opacity(0.7) : Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help(layer.enabled ? "Hide this layer" : "Show this layer")
        }
        .padding(.horizontal, 6).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.accent : Theme.hairline.opacity(0.5)))
        .contentShape(Rectangle())
        .onTapGesture { model.selectLayer(layer.id) }
        .contextMenu {
            Button("Move Up") { model.moveLayer(layer.id, by: 1) }
            Button("Move Down") { model.moveLayer(layer.id, by: -1) }
            Divider()
            Button("Delete") { model.removeLayer(layer.id) }
        }
    }
}

/// Blend, light and placement of the selected layer.
private struct LayerSettingsSection: View {
    @Bindable var model: EditorModel
    let layer: PhotoLayer

    var body: some View {
        let kit = PanelKit(model: model)
        InspectorSection(title: layer.name, icon: "photo", isEnabled: Binding(
            get: { layer.enabled }, set: { v in model.changeLayer(v ? "Show layer" : "Hide layer") { $0.enabled = v } }),
                         isExpanded: kit.expanded("layer"), isModified: false, onReset: nil) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if model.missingLayers.contains(layer.path) {
                    Text("The file \(layer.path) can't be found. Put it back, or delete this layer.")
                        .font(.system(size: 11)).foregroundStyle(Color.red.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Text("Blend").font(Theme.label).foregroundStyle(Theme.secondary)
                    Spacer()
                    Picker("", selection: Binding(get: { layer.blend }, set: { b in model.changeLayer("Blend \(b.title)") { $0.blend = b } })) {
                        ForEach(PhotoLayer.Blend.allCases, id: \.self) { b in Text(b.title).tag(b) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                Text(layer.blend.explanation)
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                slider("Amount", \.amount, 0...100, defaultValue: 100, format: { String(format: "%.0f%%", $0) })
                slider("Exposure", \.exposure, -3...3, step: 0.01, format: { String(format: "%+.2f EV", $0) })
                slider("Temperature", \.temperature, gradient: [Color(red: 0.4, green: 0.6, blue: 1), Color(white: 0.8), Color(red: 1, green: 0.8, blue: 0.35)])
                slider("Tint", \.tint, gradient: [Color(red: 0.4, green: 0.8, blue: 0.45), Color(white: 0.8), Color(red: 0.9, green: 0.45, blue: 0.85)])
                Divider().overlay(Theme.hairline)
                // Size on a log scale: 10 %…400 % of the photo's long side.
                ParameterSlider(title: "Size", value: Binding(get: { layer.size * 100 },
                                                              set: { v in model.changeLayer("Layer size") { $0.size = max(0.1, v / 100) } }),
                                range: 10...400, defaultValue: 100, format: { String(format: "%.0f%%", $0) },
                                toPosition: { log($0 / 10) / log(40) }, fromPosition: { 10 * pow(40, $0) },
                                onEditingChanged: kit.editing("Layer size"))
                ParameterSlider(title: "Rotation", value: Binding(get: { model.selectedLayerScreenAngle },
                                                                  set: { v in model.setSelectedLayerScreenAngle((v * 10).rounded() / 10) }),
                                range: -180...180, defaultValue: 0, format: { String(format: "%+.1f°", $0) }, centreMark: true,
                                onEditingChanged: kit.editing("Rotate layer"))
                HStack(spacing: 6) {
                    PlainTextButton(title: "Fill", symbol: "arrow.up.left.and.arrow.down.right") { model.placeSelectedLayer(fill: true) }
                        .help("Cover the whole frame, upright and centred")
                    PlainTextButton(title: "Fit", symbol: "arrow.down.right.and.arrow.up.left") { model.placeSelectedLayer(fill: false) }
                        .help("Show the whole layer inside the frame")
                    PlainTextButton(title: "Mirror", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                        model.changeLayer("Mirror layer") { $0.flip.toggle() }
                    }
                    .help("Flip the layer left to right")
                }
                Text("Drag on the photo to move the layer.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private func slider(_ title: String, _ kp: WritableKeyPath<PhotoLayer, Double>, _ range: ClosedRange<Double> = -100...100,
                        defaultValue: Double = 0, step: Double = 1, format: @escaping (Double) -> String = { String(format: "%+.0f", $0) },
                        gradient: [Color]? = nil) -> some View {
        let kit = PanelKit(model: model)
        return ParameterSlider(title: title, value: Binding(get: { model.selectedLayer?[keyPath: kp] ?? defaultValue },
                                                            set: { v in model.changeLayer("Layer \(title.lowercased())") { $0[keyPath: kp] = (v / step).rounded() * step } }),
                               range: range, defaultValue: defaultValue, format: format, centreMark: range.lowerBound < 0, gradient: gradient,
                               onEditingChanged: kit.editing("Layer \(title.lowercased())"))
    }
}

/// On the photo, while the Layers page is open: the selected layer's outline.
struct LayerOverlay: View {
    @Bindable var model: EditorModel

    var body: some View {
        let frame = model.canvasState.imageFrame, size = model.displaySize
        if let l = model.selectedLayer, l.enabled, size.width > 0, let corners = model.layerCorners(l) {
            let pts = corners.map { CGPoint(x: frame.minX + $0.x / size.width * frame.width, y: frame.minY + $0.y / size.height * frame.height) }
            Path { p in p.addLines(pts); p.closeSubpath() }
                .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .shadow(color: .black.opacity(0.7), radius: 1)
                .allowsHitTesting(false)
        }
    }
}
