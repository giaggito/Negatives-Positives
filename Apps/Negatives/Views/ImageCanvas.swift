import DarkroomUI
import NegativesCore
import SwiftUI

/// The photograph, centred, with the interactive tools layered on top.
struct ImageCanvas: View {
    @Bindable var model: RollModel
    @Environment(\.displayScale) private var scale

    @State private var dragRect: CGRect?        // film-base rectangle, normalised
    @State private var cropDraft: CGRect?       // crop being edited, normalised
    @State private var lastPan: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let inset: CGFloat = 28
            let area = CGRect(x: inset, y: inset, width: max(1, geo.size.width - 2 * inset), height: max(1, geo.size.height - 2 * inset))
            ZStack {
                Theme.canvas
                if let img = model.displayImage {
                    let frame = imageFrame(img, in: area)
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
                    toolLayer(frame: frame)
                    if model.showBefore { chip("Before", at: CGPoint(x: frame.minX + 34, y: frame.minY + 18)) }
                    if model.zoomCentre != nil && !model.tool.showsFullFrame { chip("100%", at: CGPoint(x: frame.maxX - 30, y: frame.minY + 18)) }
                } else if !model.hasRoll {
                    EmptyState(model: model)
                }
                if let s = model.status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(Theme.secondary)
                        Text(s).font(Theme.label).foregroundStyle(Theme.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.panel.opacity(0.92)))
                    .position(x: geo.size.width / 2, y: geo.size.height - 22)
                }
                if model.tool == .crop { cropBar.position(x: geo.size.width / 2, y: geo.size.height - 30) }
            }
            .onAppear { updateViewport(area.size) }
            .onChange(of: geo.size) { _, _ in updateViewport(area.size) }
        }
    }

    private func updateViewport(_ size: CGSize) {
        model.viewportPixels = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Where the image sits, in view points: fitted to the area, or 1:1 in device pixels when zoomed.
    private func imageFrame(_ img: CGImage, in area: CGRect) -> CGRect {
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let s = model.displayRegion != nil ? 1 / scale : min(area.width / w, area.height / h)
        return CGRect(x: area.midX - w * s / 2, y: area.midY - h * s / 2, width: w * s, height: h * s)
    }

    private func normalized(_ p: CGPoint, in f: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - f.minX) / f.width, 0), 1), y: min(max((p.y - f.minY) / f.height, 0), 1))
    }

    @ViewBuilder
    private func toolLayer(frame f: CGRect) -> some View {
        switch model.tool {
        case .filmBase:
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { g in
                            let a = normalized(g.startLocation, in: f), b = normalized(g.location, in: f)
                            dragRect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                        }
                        .onEnded { _ in
                            if let r = dragRect { model.setFilmBase(normalizedRect: r) }
                            dragRect = nil
                        })
                    .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                if let r = dragRect {
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.white)
                        .background(Color.white.opacity(0.08))
                        .frame(width: r.width * f.width, height: r.height * f.height)
                        .position(x: f.minX + r.midX * f.width, y: f.minY + r.midY * f.height)
                        .allowsHitTesting(false)
                }
            }
        case .whiteBalance:
            Color.clear.contentShape(Rectangle())
                .frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
                .onTapGesture { p in model.pickNeutral(normalized: CGPoint(x: p.x / f.width, y: p.y / f.height)) }
                .onHover { inside in if inside { NSCursor.crosshair.push() } else { NSCursor.pop() } }
        case .crop:
            CropOverlay(crop: Binding(
                get: { cropDraft ?? model.current?.settings.geometry.crop ?? CGRect(x: 0, y: 0, width: 1, height: 1) },
                set: { cropDraft = $0 }),
                        frame: f,
                        onCommit: {
                            if let c = cropDraft { model.edit(remeasure: true) { $0.geometry.crop = c } }
                            cropDraft = nil
                        })
        case .none:
            Color.clear.contentShape(Rectangle())
                .frame(width: f.width, height: f.height).position(x: f.midX, y: f.midY)
                .onTapGesture(count: 2) { p in
                    model.toggleZoom(at: CGPoint(x: p.x / f.width, y: p.y / f.height))
                }
                .gesture(DragGesture(minimumDistance: 3)
                    .onChanged { g in
                        guard model.zoomCentre != nil else { return }
                        let d = CGSize(width: (g.translation.width - lastPan.width) * scale, height: (g.translation.height - lastPan.height) * scale)
                        lastPan = g.translation
                        model.panZoom(by: d)
                    }
                    .onEnded { _ in lastPan = .zero })
        }
    }

    private var cropBar: some View {
        HStack(spacing: 14) {
            IconButton(symbol: "rotate.left", help: "Rotate left ([)") { model.rotate(clockwise: false) }
            IconButton(symbol: "rotate.right", help: "Rotate right (])") { model.rotate(clockwise: true) }
            IconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontal") { model.flip(horizontal: true) }
            IconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertical") { model.flip(horizontal: false) }
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            ParameterSlider(title: "Straighten", value: Binding(
                get: { model.current?.settings.geometry.straighten ?? 0 },
                set: { v in model.edit { $0.geometry.straighten = v } }),
                            range: -10...10, defaultValue: 0, format: { String(format: "%+.2f°", $0) }, centreMark: true)
                .frame(width: 200)
            Rectangle().fill(Theme.hairline).frame(width: 1, height: 18)
            PlainTextButton(title: "Reset") { model.edit(remeasure: true) { $0.geometry.crop = CGRect(x: 0, y: 0, width: 1, height: 1); $0.geometry.straighten = 0 } }
            PlainTextButton(title: "Done", prominent: false) { model.tool = .none }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func chip(_ text: String, at p: CGPoint) -> some View {
        Text(text).font(Theme.section).tracking(1).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .position(p)
    }
}

/// Crop rectangle with corner and edge handles; the outside is dimmed. Normalised coordinates.
struct CropOverlay: View {
    @Binding var crop: CGRect
    let frame: CGRect
    let onCommit: () -> Void
    @State private var start: CGRect?

    enum Handle: CaseIterable { case tl, tr, bl, br, t, b, l, r, move }

    var body: some View {
        let r = CGRect(x: frame.minX + crop.minX * frame.width, y: frame.minY + crop.minY * frame.height,
                       width: crop.width * frame.width, height: crop.height * frame.height)
        ZStack {
            Path { p in p.addRect(frame); p.addRect(r) }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            // Rule of thirds while editing
            Path { p in
                for i in 1...2 {
                    let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
                    p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(start == nil ? 0.0 : 0.35), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle().stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                .allowsHitTesting(false)
            handle(.move, at: CGPoint(x: r.midX, y: r.midY), size: CGSize(width: max(10, r.width - 30), height: max(10, r.height - 30)), visible: false)
            ForEach([Handle.t, .b], id: \.self) { h in
                handle(h, at: CGPoint(x: r.midX, y: h == .t ? r.minY : r.maxY), size: CGSize(width: max(10, r.width - 30), height: 14), visible: false)
            }
            ForEach([Handle.l, .r], id: \.self) { h in
                handle(h, at: CGPoint(x: h == .l ? r.minX : r.maxX, y: r.midY), size: CGSize(width: 14, height: max(10, r.height - 30)), visible: false)
            }
            ForEach([Handle.tl, .tr, .bl, .br], id: \.self) { h in
                let x = (h == .tl || h == .bl) ? r.minX : r.maxX, y = (h == .tl || h == .tr) ? r.minY : r.maxY
                handle(h, at: CGPoint(x: x, y: y), size: CGSize(width: 18, height: 18), visible: true)
            }
        }
    }

    private func handle(_ h: Handle, at p: CGPoint, size: CGSize, visible: Bool) -> some View {
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
                if start == nil { start = crop }
                guard let s = start else { return }
                let dx = g.translation.width / frame.width, dy = g.translation.height / frame.height
                var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
                let minSize = 0.05
                switch h {
                case .move:
                    let x = min(max(s.minX + dx, 0), 1 - s.width), y = min(max(s.minY + dy, 0), 1 - s.height)
                    crop = CGRect(x: x, y: y, width: s.width, height: s.height)
                    return
                case .tl: minX += dx; minY += dy
                case .tr: maxX += dx; minY += dy
                case .bl: minX += dx; maxY += dy
                case .br: maxX += dx; maxY += dy
                case .t: minY += dy
                case .b: maxY += dy
                case .l: minX += dx
                case .r: maxX += dx
                }
                minX = min(max(minX, 0), maxX - minSize); maxX = max(min(maxX, 1), minX + minSize)
                minY = min(max(minY, 0), maxY - minSize); maxY = max(min(maxY, 1), minY + minSize)
                crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in start = nil; onCommit() })
    }
}

struct EmptyState: View {
    let model: RollModel
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Theme.tertiary)
            VStack(spacing: 6) {
                Text("Negatives").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.text)
                Text("Drop a roll folder or scans here — any camera RAW, TIFF or JPEG").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            PlainTextButton(title: "Open Roll…", symbol: "folder") { model.chooseAndOpen() }
        }
    }
}
