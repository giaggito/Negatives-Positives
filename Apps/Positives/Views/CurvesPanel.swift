import DarkroomUI
import PositivesCore
import SwiftUI

struct CurvesPanel: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        let ch = model.curveChannel
        InspectorSection(title: "Curves", icon: "chart.xyaxis.line", isEnabled: kit.enabled(\.curves, "Curves"),
                         isExpanded: kit.expanded("curves"), isModified: !model.edit.curves.isNeutral,
                         onReset: { model.change("Reset curves") { $0.curves = ToneCurves() }; model.selectedCurvePoint = nil }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Segmented(options: ["RGB", "Red", "Green", "Blue"], selection: Binding(
                        get: { ch.rawValue }, set: { model.curveChannel = ToneCurves.Channel(rawValue: $0)!; model.selectedCurvePoint = nil }))
                    IconButton(symbol: "eyedropper", help: "Click a tone in the photo to put a point on the curve there", active: model.tool == .curvePoint) {
                        model.toggleTool(.curvePoint)
                    }
                }
                CurveEditor(points: CurveMath.normalized(model.edit.curves[ch]),
                            channel: ch,
                            histogram: model.histogram.bins,
                            selection: $model.selectedCurvePoint,
                            onBegin: { model.beginInteraction("Curve") },
                            onChange: { pts in model.change("Curve") { $0.curves[ch] = pts } },
                            onEnd: { model.endInteraction() },
                            onRemove: { i in
                                var pts = CurveMath.normalized(model.edit.curves[ch])
                                guard pts.count > 2 else { return }
                                pts.remove(at: i)
                                model.change("Remove curve point") { $0.curves[ch] = pts }
                                model.selectedCurvePoint = nil
                            })
                    .frame(height: 248)
                readout
                Text("Click the curve to add a point, drag to shape it, double-click a point to remove it. The pipette adds a point at the tone you click in the photo.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                if !CurveMath.isIdentity(model.edit.curves[ch]) {
                    PlainTextButton(title: "Reset \(["RGB", "red", "green", "blue"][ch.rawValue]) curve", symbol: "arrow.uturn.backward") {
                        model.change("Reset curve") { $0.curves[ch] = ToneCurves.identity }
                        model.selectedCurvePoint = nil
                    }
                }
            }
        }
    }

    @ViewBuilder private var readout: some View {
        let pts = CurveMath.normalized(model.edit.curves[model.curveChannel])
        if let i = model.selectedCurvePoint, pts.indices.contains(i) {
            HStack {
                Text("Input").font(Theme.label).foregroundStyle(Theme.tertiary)
                Text(String(format: "%.0f", pts[i].x * 255)).font(Theme.value).foregroundStyle(Theme.text)
                Spacer()
                Text("Output").font(Theme.label).foregroundStyle(Theme.tertiary)
                Text(String(format: "%.0f", pts[i].y * 255)).font(Theme.value).foregroundStyle(Theme.text)
            }
        }
    }
}

/// Interactive point curve. Coordinates 0…1, y up.
struct CurveEditor: View {
    let points: [CurvePoint]
    let channel: ToneCurves.Channel
    let histogram: [SIMD3<Float>]
    @Binding var selection: Int?
    let onBegin: () -> Void
    let onChange: ([CurvePoint]) -> Void
    let onEnd: () -> Void
    let onRemove: (Int) -> Void

    @State private var dragIndex: Int?
    @State private var working: [CurvePoint] = []

    private var tint: Color {
        switch channel {
        case .master: return Theme.accent
        case .red: return Color(red: 1, green: 0.35, blue: 0.3)
        case .green: return Color(red: 0.35, green: 0.9, blue: 0.4)
        case .blue: return Color(red: 0.4, green: 0.6, blue: 1)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let pts = dragIndex != nil ? working : points
            let toView = { (p: CurvePoint) -> CGPoint in CGPoint(x: p.x * w, y: (1 - p.y) * h) }
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35))
                Canvas { ctx, size in
                    // Histogram of the picture (luminance or the channel), as a soft backdrop.
                    if histogram.count > 1 {
                        let vals: [Float] = histogram.map { b in
                            switch channel {
                            case .master: return (b.x + b.y + b.z) / 3
                            case .red: return b.x
                            case .green: return b.y
                            case .blue: return b.z
                            }
                        }
                        let peak = max(1, vals.dropFirst().dropLast().max() ?? 1)
                        var p = Path()
                        p.move(to: CGPoint(x: 0, y: size.height))
                        for (i, v) in vals.enumerated() {
                            p.addLine(to: CGPoint(x: size.width * CGFloat(i) / CGFloat(vals.count - 1),
                                                  y: size.height * (1 - 0.9 * CGFloat(sqrt(min(1, v / peak))))))
                        }
                        p.addLine(to: CGPoint(x: size.width, y: size.height))
                        ctx.fill(p, with: .color(Color.white.opacity(0.07)))
                    }
                    var grid = Path()
                    for k in 1...3 {
                        let x = size.width * CGFloat(k) / 4, y = size.height * CGFloat(k) / 4
                        grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                    }
                    ctx.stroke(grid, with: .color(Theme.hairline), lineWidth: 0.5)
                    var diag = Path()
                    diag.move(to: CGPoint(x: 0, y: size.height)); diag.addLine(to: CGPoint(x: size.width, y: 0))
                    ctx.stroke(diag, with: .color(Theme.tertiary.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    var curve = Path()
                    for i in 0...200 {
                        let x = Double(i) / 200
                        let y = min(max(CurveMath.evaluate(pts, x), 0), 1)
                        let v = CGPoint(x: x * size.width, y: (1 - y) * size.height)
                        if i == 0 { curve.move(to: v) } else { curve.addLine(to: v) }
                    }
                    ctx.stroke(curve, with: .color(tint), lineWidth: 1.5)
                }
                ForEach(pts.indices, id: \.self) { i in
                    Circle()
                        .fill(selection == i ? tint : Theme.panel)
                        .overlay(Circle().stroke(tint, lineWidth: 1.5))
                        .frame(width: 9, height: 9)
                        .position(toView(pts[i]))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let x = min(max(Double(g.location.x / w), 0), 1), y = min(max(Double(1 - g.location.y / h), 0), 1)
                    if dragIndex == nil {
                        working = points
                        // Grab the nearest point within 10 pt, otherwise add one here.
                        let near = working.indices.min { a, b in
                            hypot(toView(working[a]).x - g.startLocation.x, toView(working[a]).y - g.startLocation.y)
                                < hypot(toView(working[b]).x - g.startLocation.x, toView(working[b]).y - g.startLocation.y)
                        }
                        onBegin()
                        if let n = near, hypot(toView(working[n]).x - g.startLocation.x, toView(working[n]).y - g.startLocation.y) < 10 {
                            dragIndex = n
                        } else {
                            let sx = min(max(Double(g.startLocation.x / w), 0), 1)
                            let sy = min(max(Double(1 - g.startLocation.y / h), 0), 1)
                            working.append(CurvePoint(sx, sy))
                            working.sort { $0.x < $1.x }
                            dragIndex = working.firstIndex { $0.x == sx && $0.y == sy }
                        }
                        selection = dragIndex
                    }
                    guard let i = dragIndex else { return }
                    let lo = i > 0 ? working[i - 1].x + 0.01 : 0
                    let hi = i < working.count - 1 ? working[i + 1].x - 0.01 : 1
                    working[i] = CurvePoint(min(max(x, lo), hi), y)
                    onChange(working)
                }
                .onEnded { _ in
                    dragIndex = nil
                    onEnd()
                })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if let s = selection, s > 0, s < points.count - 1 { onRemove(s) }
            })
        }
    }
}
