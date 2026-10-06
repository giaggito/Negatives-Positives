import DarkroomUI
import PositivesCore
import SwiftUI

/// Colour category: white balance, vibrance / saturation, colour mixer, targeted colours, colour grading.
struct ColorPanel: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        whiteBalance
        InspectorSection(title: "Color", icon: "drop", isEnabled: kit.enabled(\.color, "Color"), isExpanded: kit.expanded("color"),
                         isModified: !model.edit.color.isNeutral,
                         onReset: { model.change("Reset color") { $0.color = EditState.BasicColor() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                kit.slider("Vibrance", \.color.vibrance)
                kit.slider("Saturation", \.color.saturation, gradient: [Color(white: 0.5), Color(red: 0.95, green: 0.4, blue: 0.3)])
            }
        }
        MixerSection(model: model)
        TargetedSection(model: model)
        GradingSection(model: model)
    }

    private var whiteBalance: some View {
        let asShot = model.source?.asShotWhiteBalance ?? .neutral
        let wb = model.edit.whiteBalance ?? asShot
        let lo = WhiteBalance.temperatureRange.lowerBound, hi = WhiteBalance.temperatureRange.upperBound
        return InspectorSection(title: "White balance", icon: "thermometer.medium", isEnabled: kit.enabled(\.whiteBalance, "White balance"),
                                isExpanded: kit.expanded("wb"), isModified: model.edit.whiteBalance != nil,
                                onReset: { model.change("White balance as shot") { $0.whiteBalance = nil } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(alignment: .bottom, spacing: 8) {
                    ParameterSlider(title: "Temperature",
                                    value: Binding(get: { wb.temperature },
                                                   set: { v in model.change("Temperature") { $0.whiteBalance = WhiteBalance(temperature: v.rounded(), tint: ($0.whiteBalance ?? asShot).tint) } }),
                                    range: lo...hi, defaultValue: asShot.temperature,
                                    format: { String(format: "%.0f K", $0) },
                                    toPosition: { (1e6 / lo - 1e6 / $0) / (1e6 / lo - 1e6 / hi) },
                                    fromPosition: { 1e6 / (1e6 / lo - $0 * (1e6 / lo - 1e6 / hi)) },
                                    centreMark: true,
                                    gradient: [Color(red: 0.35, green: 0.55, blue: 0.95), Color(white: 0.8), Color(red: 0.98, green: 0.75, blue: 0.3)],
                                    onEditingChanged: kit.editing("Temperature"))
                    IconButton(symbol: "eyedropper", help: "Click something that should be neutral grey (W)", active: model.tool == .whiteBalance) {
                        model.toggleTool(.whiteBalance)
                    }
                    .padding(.bottom, -5)
                }
                ParameterSlider(title: "Tint",
                                value: Binding(get: { wb.tint },
                                               set: { v in model.change("Tint") { $0.whiteBalance = WhiteBalance(temperature: ($0.whiteBalance ?? asShot).temperature, tint: v.rounded()) } }),
                                range: WhiteBalance.tintRange, defaultValue: asShot.tint,
                                format: { String(format: "%+.0f", $0) }, centreMark: true,
                                gradient: [Color(red: 0.4, green: 0.8, blue: 0.45), Color(white: 0.8), Color(red: 0.9, green: 0.45, blue: 0.85)],
                                onEditingChanged: kit.editing("Tint"))
                if model.edit.whiteBalance == nil {
                    Text(model.isRaw ? "As shot" : "Original").font(Theme.label).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }
}

/// UI colour for an OKLab hue (degrees).
func hueColor(_ hue: Double, chroma: Double = 0.13, lightness: Double = 0.72) -> Color {
    let s = ColorMath.swatch(hue: hue, chroma: chroma, lightness: lightness)
    return Color(.sRGB, red: s.x, green: s.y, blue: s.z)
}

func degrees(_ radians: Float) -> Double { Double(radians) * 180 / .pi }

// MARK: - Colour mixer

struct MixerSection: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }
    private let centres = ColorMath.mixerCentres.map(degrees)

    var body: some View {
        InspectorSection(title: "Color mixer", icon: "swatchpalette", isEnabled: kit.enabled(\.mixer, "Color mixer"),
                         isExpanded: kit.expanded("mixer"), isModified: !model.edit.mixer.isNeutral,
                         onReset: { model.change("Reset color mixer") { $0.mixer = ColorMixer() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                Segmented(options: ["Color", "Hue", "Sat", "Lum"], selection: $model.mixerMode)
                if model.mixerMode == 0 {
                    swatches
                    let i = model.mixerSelection
                    let h = centres[i]
                    kit.slider("Hue", \.mixer.hue[i], gradient: [hueColor(h - 30), hueColor(h), hueColor(h + 30)])
                    kit.slider("Saturation", \.mixer.saturation[i], gradient: [hueColor(h, chroma: 0), hueColor(h, chroma: 0.17)])
                    kit.slider("Luminance", \.mixer.luminance[i], gradient: [hueColor(h, lightness: 0.35), hueColor(h, lightness: 0.9)])
                } else {
                    ForEach(0..<8, id: \.self) { i in
                        let h = centres[i]
                        let name = ColorMixer.names[i]
                        switch model.mixerMode {
                        case 1: kit.slider(name, \.mixer.hue[i], gradient: [hueColor(h - 30), hueColor(h), hueColor(h + 30)])
                        case 2: kit.slider(name, \.mixer.saturation[i], gradient: [hueColor(h, chroma: 0), hueColor(h, chroma: 0.17)])
                        default: kit.slider(name, \.mixer.luminance[i], gradient: [hueColor(h, lightness: 0.35), hueColor(h, lightness: 0.9)])
                        }
                    }
                }
            }
        }
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { i in
                let modified = model.edit.mixer.hue[i] != 0 || model.edit.mixer.saturation[i] != 0 || model.edit.mixer.luminance[i] != 0
                Button { model.mixerSelection = i } label: {
                    ZStack {
                        Circle().fill(hueColor(centres[i], chroma: 0.15, lightness: 0.7)).frame(width: 20, height: 20)
                        if model.mixerSelection == i { Circle().stroke(Theme.accent, lineWidth: 1.5).frame(width: 26, height: 26) }
                        if modified { Circle().fill(Theme.accent).frame(width: 4, height: 4).offset(y: 16) }
                    }
                    .frame(maxWidth: .infinity).frame(height: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ColorMixer.names[i])
            }
        }
    }
}

// MARK: - Targeted colours

struct TargetedSection: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        InspectorSection(title: "Targeted color", icon: "eyedropper.halffull", isEnabled: kit.enabled(\.targeted, "Targeted color"),
                         isExpanded: kit.expanded("targeted"), isModified: !model.edit.targeted.isEmpty,
                         onReset: { model.change("Remove targeted colors") { $0.targeted = [] }; model.targetSelection = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    PlainTextButton(title: model.tool == .targetColor ? "Click a colour in the photo…" : "Pick a colour", symbol: "eyedropper") {
                        model.toggleTool(.targetColor)
                    }
                    .disabled(model.edit.targeted.count >= TargetedColor.maximumCount)
                    Spacer()
                }
                ForEach(Array(model.edit.targeted.enumerated()), id: \.element.id) { i, t in row(i, t) }
                if let i = model.targetSelection, model.edit.targeted.indices.contains(i) {
                    controls(i)
                } else if model.edit.targeted.isEmpty {
                    Text("Pick a colour on the photo to adjust only that colour, or keep it and turn everything else black & white.")
                        .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func row(_ i: Int, _ t: TargetedColor) -> some View {
        let selected = model.targetSelection == i
        return HStack(spacing: 8) {
            Circle().fill(hueColor(t.hue, chroma: min(t.chroma, 0.16), lightness: min(max(t.lightness, 0.45), 0.85))).frame(width: 14, height: 14)
            Text("Colour \(i + 1)").font(Theme.label).foregroundStyle(selected ? Theme.text : Theme.secondary)
            Spacer()
            IconButton(symbol: model.showTargetOverlay && selected ? "eye.fill" : "eye", help: "Show what this colour selects", active: model.showTargetOverlay && selected) {
                model.targetSelection = i
                model.showTargetOverlay.toggle()
            }
            PowerToggle(isOn: Binding(get: { t.enabled }, set: { v in model.change("Colour \(i + 1) \(v ? "on" : "off")") { $0.targeted[i].enabled = v } }))
            IconButton(symbol: "xmark", help: "Remove") {
                model.showTargetOverlay = false
                model.change("Remove colour \(i + 1)") { $0.targeted.remove(at: i) }
                model.targetSelection = model.edit.targeted.isEmpty ? nil : min(i, model.edit.targeted.count - 1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.hairline : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.targetSelection = i }
    }

    private func controls(_ i: Int) -> some View {
        let t = model.edit.targeted[i]
        let h = t.hue
        // Range and softness show the selection while they are dragged.
        func rangeSlider(_ title: String, _ kp: WritableKeyPath<EditState, Double>, _ range: ClosedRange<Double>, _ def: Double) -> some View {
            ParameterSlider(title: title, value: Binding(get: { model.edit[keyPath: kp] }, set: { v in model.change(title) { $0[keyPath: kp] = v.rounded() } }),
                            range: range, defaultValue: def, format: { String(format: "%.0f", $0) },
                            onEditingChanged: { on in
                                model.showTargetOverlay = on
                                on ? model.beginInteraction(title) : model.endInteraction()
                            })
        }
        return VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
            kit.slider("Hue", \.targeted[i].hueShift, gradient: [hueColor(h - 30), hueColor(h), hueColor(h + 30)])
            kit.slider("Saturation", \.targeted[i].saturation, gradient: [hueColor(h, chroma: 0), hueColor(h, chroma: 0.17)])
            kit.slider("Luminance", \.targeted[i].luminance, gradient: [hueColor(h, lightness: 0.35), hueColor(h, lightness: 0.9)])
            ParameterSlider(title: "Keep only this colour", value: Binding(get: { t.isolate }, set: { v in model.change("Isolate") { $0.targeted[i].isolate = v.rounded() } }),
                            range: 0...100, defaultValue: 0, format: { String(format: "%.0f", $0) },
                            gradient: [Color(white: 0.5), hueColor(h)], onEditingChanged: kit.editing("Isolate"))
            rangeSlider("Range", \.targeted[i].width, 5...90, 25)
            rangeSlider("Softness", \.targeted[i].softness, 0...100, 50)
        }
        .padding(.top, 4)
    }
}

// MARK: - Colour grading

struct GradingSection: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }
    private let zones: [(String, WritableKeyPath<ColorGrading, ColorGrading.Wheel>)] =
        [("Shadows", \.shadows), ("Midtones", \.midtones), ("Highlights", \.highlights), ("Global", \.global)]

    var body: some View {
        let z = zones[model.gradingZone]
        let wheelPath = (\EditState.grading).appending(path: z.1)
        InspectorSection(title: "Color grading", icon: "circle.circle", isEnabled: kit.enabled(\.grading, "Color grading"),
                         isExpanded: kit.expanded("grading"), isModified: !model.edit.grading.isNeutral,
                         onReset: { model.change("Reset color grading") { $0.grading = ColorGrading() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                HStack(spacing: 4) {
                    ForEach(zones.indices, id: \.self) { i in zoneButton(i) }
                }
                ColorWheel(hue: Binding(get: { model.edit[keyPath: wheelPath].hue },
                                        set: { v in model.change("\(z.0) colour") { $0[keyPath: wheelPath].hue = v } }),
                           saturation: Binding(get: { model.edit[keyPath: wheelPath].saturation },
                                               set: { v in model.change("\(z.0) colour") { $0[keyPath: wheelPath].saturation = v } }),
                           onEditingChanged: kit.editing("\(z.0) colour"))
                    .frame(width: 176, height: 176)
                    .frame(maxWidth: .infinity)
                kit.slider("Luminance", wheelPath.appending(path: \.luminance))
                kit.slider("Blending", \.grading.blending, range: 0...100, defaultValue: 50, format: { String(format: "%.0f", $0) })
                kit.slider("Balance", \.grading.balance)
            }
        }
    }

    private func zoneButton(_ i: Int) -> some View {
        let w = model.edit.grading[keyPath: zones[i].1]
        let selected = model.gradingZone == i
        return Button { model.gradingZone = i } label: {
            VStack(spacing: 4) {
                Circle()
                    .fill(w.saturation > 0 ? hueColor(w.hue, chroma: 0.04 + 0.11 * w.saturation / 100) : Theme.track)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(selected ? Theme.accent : .clear, lineWidth: 1.5).padding(-3))
                Text(zones[i].0).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.tertiary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A hue / saturation wheel: angle = hue (OKLab), distance from the centre = strength. Double-click resets.
struct ColorWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            // Screen angle θ (clockwise from 3 o'clock) shows hue 360° − θ, so the puck at hue h sits at (cos h, −sin h).
            let stops = stride(from: 0.0, through: 360.0, by: 10).map { Gradient.Stop(color: hueColor(360 - $0, chroma: 0.15, lightness: 0.68), location: $0 / 360) }
            let a = hue * .pi / 180, d = saturation / 100 * Double(r)
            ZStack {
                Circle().fill(AngularGradient(gradient: Gradient(stops: stops), center: .center))
                Circle().fill(RadialGradient(colors: [Color(white: 0.58), Color(white: 0.58).opacity(0)], center: .center, startRadius: 0, endRadius: r))
                Circle().stroke(Theme.hairline, lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: c.x - 6, y: c.y)); p.addLine(to: CGPoint(x: c.x + 6, y: c.y))
                    p.move(to: CGPoint(x: c.x, y: c.y - 6)); p.addLine(to: CGPoint(x: c.x, y: c.y + 6))
                }
                .stroke(Color.black.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(saturation > 0 ? hueColor(hue, chroma: 0.15, lightness: 0.7) : Color(white: 0.6))
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .frame(width: dragging ? 16 : 13, height: dragging ? 16 : 13)
                    .position(x: c.x + CGFloat(cos(a) * d), y: c.y - CGFloat(sin(a) * d))
            }
            .frame(width: size, height: size)
            .position(c)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    let dx = Double(g.location.x - c.x), dy = Double(c.y - g.location.y)
                    let rr = min(1, (dx * dx + dy * dy).squareRoot() / Double(r))
                    var h = atan2(dy, dx) * 180 / .pi
                    if h < 0 { h += 360 }
                    hue = h.rounded()
                    saturation = (rr * 100).rounded()
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
            .onTapGesture(count: 2) { onEditingChanged(true); saturation = 0; onEditingChanged(false) }
        }
        .help("Drag to tint; double-click to reset")
    }
}
