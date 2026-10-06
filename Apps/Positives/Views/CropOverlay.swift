import DarkroomUI
import PositivesCore
import SwiftUI

/// Crop tool: the whole frame is shown; drag corners or edges (kept to the chosen ratio), drag inside to move.
/// Rule-of-thirds lines show while the crop is being edited.
struct CropOverlay: View {
    @Bindable var model: EditorModel
    @State private var start: CGRect?

    enum Handle: CaseIterable { case tl, tr, bl, br, t, b, l, r, move }

    var body: some View {
        let frame = model.canvasState.imageFrame
        let crop = model.edit.geometry.crop
        let r = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                       width: crop.width * frame.width, height: crop.height * frame.height)
        ZStack {
            Path { p in p.addRect(frame); p.addRect(r) }
                .fill(Color.black.opacity(0.6), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
            handle(.move, at: CGPoint(x: r.midX, y: r.midY), size: CGSize(width: max(10, r.width - 30), height: max(10, r.height - 30)), visible: false, frame: frame)
            ForEach([Handle.t, .b], id: \.self) { h in
                handle(h, at: CGPoint(x: r.midX, y: h == .t ? r.minY : r.maxY), size: CGSize(width: max(10, r.width - 30), height: 14), visible: false, frame: frame)
            }
            ForEach([Handle.l, .r], id: \.self) { h in
                handle(h, at: CGPoint(x: h == .l ? r.minX : r.maxX, y: r.midY), size: CGSize(width: 14, height: max(10, r.height - 30)), visible: false, frame: frame)
            }
            ForEach([Handle.tl, .tr, .bl, .br], id: \.self) { h in
                let x = (h == .tl || h == .bl) ? r.minX : r.maxX, y = (h == .tl || h == .tr) ? r.minY : r.maxY
                handle(h, at: CGPoint(x: x, y: y), size: CGSize(width: 20, height: 20), visible: true, frame: frame)
            }
        }
    }

    private func handle(_ h: Handle, at p: CGPoint, size: CGSize, visible: Bool, frame: CGRect) -> some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            if visible {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.white).frame(width: 8, height: 8)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
            }
        }
        .frame(width: size.width, height: size.height)
        .position(p)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if start == nil { start = model.edit.geometry.crop; model.beginInteraction("Crop") }
                guard let s = start, frame.width > 0 else { return }
                let dx = g.translation.width / frame.width, dy = g.translation.height / frame.height
                let next = Self.drag(h, start: s, dx: dx, dy: dy, ratio: model.edit.cropAspect.ratio(original: model.frameAspect),
                                     frameAspect: model.frameAspect)
                let constrained = CropMath.constrain(next, straighten: model.edit.geometry.straighten, frameAspect: model.frameAspect)
                model.change("Crop") { $0.geometry.crop = constrained }
            }
            .onEnded { _ in start = nil; model.endInteraction() })
    }

    /// New crop rectangle (normalised) for a handle dragged by (dx, dy), keeping `ratio` (long / short side) if set.
    static func drag(_ h: Handle, start s: CGRect, dx: CGFloat, dy: CGFloat, ratio: Double?, frameAspect: Double) -> CGRect {
        let minSize = 0.04
        if h == .move {
            return CGRect(x: min(max(s.minX + dx, 0), 1 - s.width), y: min(max(s.minY + dy, 0), 1 - s.height), width: s.width, height: s.height)
        }
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch h {
        case .tl: minX += dx; minY += dy
        case .tr: maxX += dx; minY += dy
        case .bl: minX += dx; maxY += dy
        case .br: maxX += dx; maxY += dy
        case .t: minY += dy
        case .b: maxY += dy
        case .l: minX += dx
        case .r: maxX += dx
        case .move: break
        }
        minX = min(max(minX, 0), maxX - minSize); maxX = max(min(maxX, 1), minX + minSize)
        minY = min(max(minY, 0), maxY - minSize); maxY = max(min(maxY, 1), minY + minSize)
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio else { return r }
        // Keep the ratio in pixels, in the orientation the crop had when the drag started.
        let landscape = s.width * frameAspect >= s.height
        let target = (landscape ? ratio : 1 / ratio) / frameAspect     // normalised width / height
        switch h {
        case .t, .b:
            let w = r.height * target
            r = CGRect(x: s.midX - w / 2, y: r.minY, width: w, height: r.height)
        case .l, .r:
            let hh = r.width / target
            r = CGRect(x: r.minX, y: s.midY - hh / 2, width: r.width, height: hh)
        default:
            // Corners: follow the larger movement, anchored at the opposite corner.
            var w = r.width, hh = r.height
            if w / target > hh { hh = w / target } else { w = hh * target }
            let ax = (h == .tl || h == .bl) ? s.maxX : s.minX, ay = (h == .tl || h == .tr) ? s.maxY : s.minY
            r = CGRect(x: (h == .tl || h == .bl) ? ax - w : ax, y: (h == .tl || h == .tr) ? ay - hh : ay, width: w, height: hh)
        }
        // Shrink to fit the frame if needed, keeping the ratio.
        let k = min(1, r.minX < 0 ? (r.maxX) / r.width : 1, r.maxX > 1 ? (1 - r.minX) / r.width : 1,
                    r.minY < 0 ? r.maxY / r.height : 1, r.maxY > 1 ? (1 - r.minY) / r.height : 1)
        if k < 1 {
            let w = r.width * k, hh = r.height * k
            let ax = (h == .tl || h == .bl) ? r.maxX : r.minX, ay = (h == .tl || h == .tr) ? r.maxY : r.minY
            r = CGRect(x: (h == .tl || h == .bl) ? ax - w : ax, y: (h == .tl || h == .tr) ? ay - hh : ay, width: w, height: hh)
        }
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        return r
    }

}


/// Crop controls, shown in a strip under the picture while cropping.
struct CropBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { model.edit.cropAspect }, set: { model.setCropAspect($0) })) {
                ForEach(CropAspect.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 92)
            .help("Aspect ratio")
            IconButton(symbol: "rectangle.portrait.rotate", help: "Swap orientation of the crop") { swapOrientation() }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            IconButton(symbol: "rotate.left", help: "Rotate left ([)") { model.rotate(clockwise: false) }
            IconButton(symbol: "rotate.right", help: "Rotate right (])") { model.rotate(clockwise: true) }
            IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") { model.flip(horizontal: true) }
            IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical") { model.flip(horizontal: false) }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            ParameterSlider(title: "Straighten", value: Binding(get: { model.edit.geometry.straighten }, set: { model.setStraighten(($0 * 20).rounded() / 20) }),
                            range: -15...15, defaultValue: 0, format: { String(format: "%+.2f°", $0) }, centreMark: true,
                            onEditingChanged: { $0 ? model.beginInteraction("Straighten") : model.endInteraction() })
                .frame(width: 200)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            PlainTextButton(title: "Reset") { model.resetCrop() }
            PlainTextButton(title: "Done", prominent: true) { model.tool = .none }
                .frame(width: 70)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(Theme.panel)
    }

    private func swapOrientation() {
        let a = model.frameAspect
        model.change("Crop orientation") { e in
            let c = e.geometry.crop
            // Same pixel area, width and height exchanged, centred where it was.
            let wPx = c.height * 1 / a, hPx = c.width * a
            var r = CGRect(x: c.midX - wPx / 2, y: c.midY - hPx / 2, width: wPx, height: hPx)
            let k = min(1, 1 / r.width, 1 / r.height)
            r = CGRect(x: c.midX - r.width * k / 2, y: c.midY - r.height * k / 2, width: r.width * k, height: r.height * k)
            r.origin.x = min(max(r.minX, 0), 1 - r.width)
            r.origin.y = min(max(r.minY, 0), 1 - r.height)
            e.geometry.crop = CropMath.constrain(r, straighten: e.geometry.straighten, frameAspect: a)
        }
    }
}
