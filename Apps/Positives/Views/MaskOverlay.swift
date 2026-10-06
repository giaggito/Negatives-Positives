import DarkroomUI
import PositivesCore
import SwiftUI

/// On the photo, for the selected mask part: the brush outline under the pointer, and handles for gradients
/// (linear: start, end, move; radial: centre, both radii, rotation). Everything else lets clicks through to
/// the canvas, where drags paint or draw a new gradient.
struct MaskOverlay: View {
    @Bindable var model: EditorModel
    @State private var start: MaskComponent?

    private var frame: CGRect { model.canvasState.imageFrame }
    private var size: CGSize { model.displaySize }

    private func toView(_ p: CGPoint) -> CGPoint {
        guard size.width > 0 else { return .zero }
        return CGPoint(x: frame.minX + p.x / size.width * frame.width, y: frame.minY + p.y / size.height * frame.height)
    }
    private func toImage(_ v: CGPoint) -> CGPoint {
        guard frame.width > 0 else { return .zero }
        return CGPoint(x: (v.x - frame.minX) / frame.width * size.width, y: (v.y - frame.minY) / frame.height * size.height)
    }
    private func view(_ m: MaskPoint) -> CGPoint { toView(model.imagePoint(m)) }
    private func mask(_ v: CGPoint) -> MaskPoint { model.maskPoint(toImage(v)) }
    /// Screen points per mask unit (the long side of the sensor).
    private var unit: CGFloat {
        let a = view(MaskPoint(0, 0)), b = view(MaskPoint(0.01, 0))
        return hypot(b.x - a.x, b.y - a.y) * 100
    }

    var body: some View {
        ZStack {
            if let part = model.selectedPart, model.tool == .none {
                switch part.kind {
                case .linear: linear(part)
                case .radial: radial(part)
                default: EmptyView()
                }
            }
            if model.canvasDrawKind == .brush, let h = model.hoverPoint {
                let c = toView(h)
                let r = CGFloat(model.brushSize) * unit
                Circle().stroke(Color.white, lineWidth: 1).shadow(color: .black.opacity(0.8), radius: 1)
                    .frame(width: 2 * r, height: 2 * r).position(c)
                    .allowsHitTesting(false)
                if model.brushFeather > 2 {
                    let ri = r * CGFloat(1 - model.brushFeather / 100)
                    Circle().stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: 2 * ri, height: 2 * ri).position(c)
                        .allowsHitTesting(false)
                }
            }
        }
        .coordinateSpace(name: "maskOverlay")
    }

    // MARK: Linear gradient

    @ViewBuilder
    private func linear(_ c: MaskComponent) -> some View {
        let s = view(c.start), e = view(c.end)
        let d = CGPoint(x: e.x - s.x, y: e.y - s.y)
        let len = max(hypot(d.x, d.y), 1)
        let n = CGPoint(x: -d.y / len * 4000, y: d.x / len * 4000)
        let mid = CGPoint(x: (s.x + e.x) / 2, y: (s.y + e.y) / 2)
        Path { p in
            for q in [s, e] { p.move(to: CGPoint(x: q.x - n.x, y: q.y - n.y)); p.addLine(to: CGPoint(x: q.x + n.x, y: q.y + n.y)) }
        }
        .stroke(Color.white.opacity(0.85), lineWidth: 1)
        .shadow(color: .black.opacity(0.7), radius: 1)
        .clipShape(Rectangle().path(in: frame))
        .allowsHitTesting(false)
        Path { p in p.move(to: CGPoint(x: mid.x - n.x, y: mid.y - n.y)); p.addLine(to: CGPoint(x: mid.x + n.x, y: mid.y + n.y)) }
            .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .clipShape(Rectangle().path(in: frame))
            .allowsHitTesting(false)
        handle(at: s, label: "Fully applied here") { c0, v in var c = c0; c.start = mask(v); return c }
        handle(at: e, label: "Not applied beyond here") { c0, v in var c = c0; c.end = mask(v); return c }
        handle(at: mid, label: "Move", ring: true) { c0, v in
            var c = c0
            let s0 = view(c0.start), e0 = view(c0.end)
            let m0 = CGPoint(x: (s0.x + e0.x) / 2, y: (s0.y + e0.y) / 2)
            let dx = v.x - m0.x, dy = v.y - m0.y
            c.start = mask(CGPoint(x: s0.x + dx, y: s0.y + dy)); c.end = mask(CGPoint(x: e0.x + dx, y: e0.y + dy))
            return c
        }
    }

    // MARK: Radial gradient

    private func ellipse(_ c: MaskComponent, scale k: Double) -> Path {
        Path { p in
            let a = c.angle * .pi / 180
            for i in 0...96 {
                let t = Double(i) / 96 * 2 * .pi
                let lx = c.radiusX * k * cos(t), ly = c.radiusY * k * sin(t)
                let q = view(MaskPoint(c.center.x + lx * cos(a) - ly * sin(a), c.center.y + lx * sin(a) + ly * cos(a)))
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
        }
    }

    @ViewBuilder
    private func radial(_ c: MaskComponent) -> some View {
        let a = c.angle * .pi / 180
        let ax = view(MaskPoint(c.center.x + c.radiusX * cos(a), c.center.y + c.radiusX * sin(a)))
        let ay = view(MaskPoint(c.center.x - c.radiusY * sin(a), c.center.y + c.radiusY * cos(a)))
        let rot = view(MaskPoint(c.center.x - c.radiusY * 1.25 * sin(a), c.center.y + c.radiusY * 1.25 * cos(a)))
        ellipse(c, scale: 1).stroke(Color.white.opacity(0.85), lineWidth: 1).shadow(color: .black.opacity(0.7), radius: 1)
            .allowsHitTesting(false)
        if c.feather > 1 {
            ellipse(c, scale: 1 - c.feather / 100).stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .allowsHitTesting(false)
        }
        handle(at: view(c.center), label: "Move", ring: true) { c0, v in var c = c0; c.center = mask(v); return c }
        handle(at: ax, label: "Width") { c0, v in
            var c = c0
            let m = mask(v), an = c0.angle * .pi / 180
            c.radiusX = max(0.005, abs((m.x - c0.center.x) * cos(an) + (m.y - c0.center.y) * sin(an)))
            return c
        }
        handle(at: ay, label: "Height") { c0, v in
            var c = c0
            let m = mask(v), an = c0.angle * .pi / 180
            c.radiusY = max(0.005, abs(-(m.x - c0.center.x) * sin(an) + (m.y - c0.center.y) * cos(an)))
            return c
        }
        handle(at: rot, label: "Rotate", small: true) { c0, v in
            var c = c0
            let m = mask(v)
            // The rotation handle sits on the local +y axis: angle of (m − centre) minus 90°.
            c.angle = atan2(m.y - c0.center.y, m.x - c0.center.x) * 180 / .pi - 90
            return c
        }
    }

    // MARK: Handles

    private func handle(at p: CGPoint, label: String, ring: Bool = false, small: Bool = false,
                        _ update: @escaping (MaskComponent, CGPoint) -> MaskComponent) -> some View {
        ZStack {
            Circle().fill(Color.clear).frame(width: 22, height: 22).contentShape(Circle())
            if ring {
                Circle().stroke(Color.white, lineWidth: 2).frame(width: 12, height: 12).shadow(color: .black.opacity(0.7), radius: 1.5)
            } else {
                Circle().fill(Color.white).frame(width: small ? 7 : 9, height: small ? 7 : 9).shadow(color: .black.opacity(0.7), radius: 1.5)
            }
        }
        .position(p)
        .help(label)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("maskOverlay"))
            .onChanged { g in
                if start == nil {
                    start = model.selectedPart
                    model.beginInteraction("Adjust gradient")
                    model.maskDragging = true
                }
                guard let s = start else { return }
                let next = update(s, g.location)
                model.changePart("Adjust gradient") { $0 = next }
            }
            .onEnded { _ in
                start = nil
                model.endInteraction()
                model.maskDragging = false
            })
    }
}
