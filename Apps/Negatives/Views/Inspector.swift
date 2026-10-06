import DarkroomUI
import NegativesCore
import simd
import SwiftUI

struct Inspector: View {
    @Bindable var model: RollModel
    @Binding var showExport: Bool

    private func binding<T>(_ kp: WritableKeyPath<FrameSettings, T>, remeasure: Bool = false) -> Binding<T> {
        Binding(
            get: { model.current?.settings[keyPath: kp] ?? FrameSettings()[keyPath: kp] },
            set: { v in model.edit(remeasure: remeasure) { $0[keyPath: kp] = v } }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { content }.scrollIndicators(.never)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            VStack(spacing: 8) {
                PlainTextButton(title: "Export…", symbol: "square.and.arrow.up", prominent: true) { showExport = true }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.hasRoll)
            }
            .padding(14)
        }
        .frame(width: 272)
        .background(Theme.panel)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            filmBase
            tone
            color
            advancedToggle
            if model.showAdvanced { advanced }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.current?.name ?? "No frame")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            if let s = model.selection {
                Text("Frame \(s + 1) of \(model.frames.count)\(model.isFullQuality ? "" : " · preview quality")")
                    .font(Theme.value).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var filmBase: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Film base")
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(baseSwatch)
                    .frame(width: 26, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.roll.filmBase == nil ? "Not measured" : (model.roll.filmBaseSource?.rect == nil ? "Automatic" : "Measured"))
                        .font(Theme.label).foregroundStyle(Theme.text)
                    if let f = model.roll.filmBaseSource?.file {
                        Text("on \((f as NSString).deletingPathExtension)").font(Theme.value).foregroundStyle(Theme.tertiary)
                    }
                }
                Spacer()
                IconButton(symbol: "rectangle.dashed", help: "Drag a rectangle over clear film between frames (B)", active: model.tool == .filmBase) {
                    model.tool = model.tool == .filmBase ? .none : .filmBase
                }
                IconButton(symbol: "wand.and.stars", help: "Estimate automatically") { model.autoFilmBase() }
            }
            if model.tool == .filmBase {
                Text("Drag over the clear orange film between frames or along the edge.")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var baseSwatch: Color {
        guard let b = model.roll.filmBase, let m = model.cameraToSRGB else { return Theme.hairline }
        let v = m * (b / max(b.max(), 1e-6) * 0.9)
        func enc(_ x: Double) -> Double { OutputColorSpace.sRGB.encode(min(max(x, 0), 1)) }
        return Color(.sRGB, red: enc(v.x), green: enc(v.y), blue: enc(v.z))
    }

    private var tone: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Tone")
            ParameterSlider(title: "Exposure", value: binding(\.exposure), range: -3...3, defaultValue: 0,
                            format: { String(format: "%+.2f EV", $0) }, centreMark: true)
            ParameterSlider(title: "Contrast", value: binding(\.curve.contrast), range: 0.5...2.5, defaultValue: PrintCurve().contrast,
                            format: { String(format: "%.2f", $0) }, centreMark: true)
        }
    }

    private var color: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Colour")
            Segmented(options: ["Colour", "Black & White"], selection: Binding(
                get: { (model.current?.settings.monochrome ?? model.roll.monochrome) ? 1 : 0 },
                set: { v in model.edit { $0.monochrome = v == 1 } }))
            let mono = model.current?.settings.monochrome ?? model.roll.monochrome
            if !mono {
                HStack(alignment: .bottom, spacing: 8) {
                    ParameterSlider(title: "Temperature", value: binding(\.whiteBalance.temperature), range: 2500...15000,
                                    defaultValue: WhiteBalance.referenceTemperature,
                                    format: { String(format: "%.0f K", $0) },
                                    toPosition: { (1e6 / 2500 - 1e6 / $0) / (1e6 / 2500 - 1e6 / 15000) },
                                    fromPosition: { 1e6 / (1e6 / 2500 - $0 * (1e6 / 2500 - 1e6 / 15000)) },
                                    centreMark: true,
                                    gradient: [Color(red: 0.35, green: 0.55, blue: 0.95), Color(white: 0.8), Color(red: 0.98, green: 0.75, blue: 0.3)])
                    IconButton(symbol: "eyedropper", help: "Click something that should be neutral grey (W)", active: model.tool == .whiteBalance) {
                        model.tool = model.tool == .whiteBalance ? .none : .whiteBalance
                    }
                    .padding(.bottom, -5)
                }
                ParameterSlider(title: "Tint", value: binding(\.whiteBalance.tint), range: -100...100, defaultValue: 0,
                                format: { String(format: "%+.0f", $0) }, centreMark: true,
                                gradient: [Color(red: 0.4, green: 0.8, blue: 0.45), Color(white: 0.8), Color(red: 0.9, green: 0.45, blue: 0.85)])
            }
        }
    }

    private var advancedToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { model.showAdvanced.toggle() }
        } label: {
            HStack {
                SectionHeader(title: "Advanced")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .rotationEffect(.degrees(model.showAdvanced ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            ParameterSlider(title: "Shadows roll-off", value: binding(\.curve.toe), range: 0...1, defaultValue: PrintCurve().toe)
            ParameterSlider(title: "Highlights roll-off", value: binding(\.curve.shoulder), range: 0...1, defaultValue: PrintCurve().shoulder)
            ParameterSlider(title: "Paper black", value: binding(\.curve.paperDmax), range: 1.6...3.4, defaultValue: PrintCurve().paperDmax,
                            format: { String(format: "%.2f D", $0) })
            Toggle(isOn: binding(\.autoExposureEnabled)) {
                Text("Automatic exposure per frame").font(Theme.label).foregroundStyle(Theme.secondary)
            }
            .toggleStyle(.switch).controlSize(.mini)

            if model.current?.settings.monochrome ?? model.roll.monochrome {
                SectionHeader(title: "Black & white mix")
                ParameterSlider(title: "Red", value: binding(\.monochromeWeights.x), range: 0...1, defaultValue: 0.25)
                ParameterSlider(title: "Green", value: binding(\.monochromeWeights.y), range: 0...1, defaultValue: 0.5)
                ParameterSlider(title: "Blue", value: binding(\.monochromeWeights.z), range: 0...1, defaultValue: 0.25)
            }

            SectionHeader(title: "Film calibration (roll)")
            ParameterSlider(title: "Film gamma", value: Binding(get: { model.roll.filmGamma }, set: { v in model.editRoll { $0.filmGamma = v } }),
                            range: 0.4...0.9, defaultValue: 0.6)
            calibrationSliders
            HStack {
                PlainTextButton(title: "Re-analyse roll", symbol: "arrow.triangle.2.circlepath") { model.remeasureAll() }
                Spacer()
            }

            SectionHeader(title: "Flat field")
            HStack {
                Text(model.roll.flatFieldFile.map { ($0 as NSString).lastPathComponent } ?? "None")
                    .font(Theme.label).foregroundStyle(model.roll.flatFieldFile == nil ? Theme.tertiary : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.roll.flatFieldFile != nil {
                    IconButton(symbol: "xmark", help: "Remove flat field") { model.clearFlatField() }
                }
                PlainTextButton(title: "Choose…") { model.chooseFlatField() }
            }
            Text("A shot of the bare light panel, same setup, no film. Removes vignetting and uneven light.")
                .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-layer gamma ratio and offset relative to green. Editing creates a per-frame override.
    private var calibrationSliders: some View {
        let roll = model.roll.calibration ?? .identity
        func cal(_ kp: WritableKeyPath<FilmCalibration, Double>) -> Binding<Double> {
            Binding(get: { (model.current?.settings.calibrationOverride ?? roll)[keyPath: kp] },
                    set: { v in model.edit { s in
                        var c = s.calibrationOverride ?? roll
                        c[keyPath: kp] = v
                        s.calibrationOverride = c
                    } })
        }
        return VStack(alignment: .leading, spacing: 16) {
            ParameterSlider(title: "Red layer gamma", value: cal(\.gammaRatio.x), range: 0.6...1.4, defaultValue: roll.gammaRatio.x,
                            format: { String(format: "%.3f", $0) }, centreMark: true)
            ParameterSlider(title: "Blue layer gamma", value: cal(\.gammaRatio.z), range: 0.6...1.6, defaultValue: roll.gammaRatio.z,
                            format: { String(format: "%.3f", $0) }, centreMark: true)
            ParameterSlider(title: "Red offset", value: cal(\.offset.x), range: (roll.offset.x - 0.3)...(roll.offset.x + 0.3), defaultValue: roll.offset.x,
                            format: { String(format: "%+.3f", $0) }, centreMark: true)
            ParameterSlider(title: "Blue offset", value: cal(\.offset.z), range: (roll.offset.z - 0.3)...(roll.offset.z + 0.3), defaultValue: roll.offset.z,
                            format: { String(format: "%+.3f", $0) }, centreMark: true)
            if model.current?.settings.calibrationOverride != nil {
                PlainTextButton(title: "Use roll calibration", symbol: "arrow.uturn.backward") { model.edit { $0.calibrationOverride = nil } }
            }
        }
    }
}
