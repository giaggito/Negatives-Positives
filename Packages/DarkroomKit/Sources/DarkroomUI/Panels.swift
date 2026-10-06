import SwiftUI

/// One cell in a filmstrip.
public struct FilmstripItem: Identifiable {
    public let id: AnyHashable
    public var thumbnail: CGImage?
    public var label: String
    public var help: String
    /// Small mark in the corner (e.g. "edited").
    public var badge: Bool

    public init(id: AnyHashable, thumbnail: CGImage?, label: String, help: String, badge: Bool = false) {
        self.id = id
        self.thumbnail = thumbnail
        self.label = label
        self.help = help
        self.badge = badge
    }
}

/// Horizontal strip of thumbnails. `selection` is the focused item; `marked` are additional selected items
/// (⌘-click / ⇧-click) for batch operations.
public struct Filmstrip: View {
    let items: [FilmstripItem]
    let selection: Int?
    let marked: Set<Int>
    let onSelect: (Int, NSEvent.ModifierFlags) -> Void

    public init(items: [FilmstripItem], selection: Int?, marked: Set<Int> = [], onSelect: @escaping (Int, NSEvent.ModifierFlags) -> Void) {
        self.items = items
        self.selection = selection
        self.marked = marked
        self.onSelect = onSelect
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        FilmstripThumb(item: item, index: i, selected: selection == i, marked: marked.contains(i))
                            .id(item.id)
                            .onTapGesture { onSelect(i, NSEvent.modifierFlags) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .onChange(of: selection) { _, s in
                if let s, items.indices.contains(s) {
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(items[s].id, anchor: .center) }
                }
            }
        }
        .frame(height: 104)
        .background(Theme.panel)
    }
}

private struct FilmstripThumb: View {
    let item: FilmstripItem
    let index: Int
    let selected: Bool
    let marked: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let t = item.thumbnail {
                        Image(decorative: t, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.hairline)
                            .overlay(ProgressView().controlSize(.mini))
                    }
                }
                .frame(width: 96, height: 64)
                if item.badge {
                    Circle().fill(Theme.accent.opacity(0.85)).frame(width: 5, height: 5).padding(4)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 2)
                .stroke(selected ? Theme.accent : (marked ? Theme.secondary : .clear), lineWidth: selected ? 1.5 : 1)
                .padding(-3))
            .opacity(selected || marked || hover ? 1 : 0.72)
            Text(item.label).font(Theme.value).foregroundStyle(selected ? Theme.text : Theme.tertiary).lineLimit(1)
        }
        .frame(width: 96)
        .onHover { hover = $0 }
        .help(item.help)
    }
}

/// RGB histogram (display-encoded bins), drawn additively. Optional clipping indicators: the small
/// triangles light up when shadows / highlights clip, and toggle the clipping overlay when clicked.
public struct HistogramView: View {
    let bins: [SIMD3<Float>]
    var shadowClip: Double
    var highlightClip: Double
    var showsClipping: Binding<Bool>?

    public init(bins: [SIMD3<Float>], shadowClip: Double = 0, highlightClip: Double = 0, showsClipping: Binding<Bool>? = nil) {
        self.bins = bins
        self.shadowClip = shadowClip
        self.highlightClip = highlightClip
        self.showsClipping = showsClipping
    }

    public var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                guard bins.count > 1 else { return }
                // Ignore the extreme bins when scaling so clipped ends don't flatten the curve.
                let peak = bins.dropFirst().dropLast().map { max($0.x, $0.y, $0.z) }.max() ?? 1
                let colors: [Color] = [Color(red: 1, green: 0.32, blue: 0.3), Color(red: 0.35, green: 0.9, blue: 0.4), Color(red: 0.35, green: 0.55, blue: 1)]
                ctx.blendMode = .plusLighter
                for k in 0..<3 {
                    var p = Path()
                    p.move(to: CGPoint(x: 0, y: size.height))
                    for (i, b) in bins.enumerated() {
                        let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                        let v = min(1, CGFloat(b[k] / max(peak, 1)))
                        p.addLine(to: CGPoint(x: x, y: size.height * (1 - sqrt(v) * 0.95)))
                    }
                    p.addLine(to: CGPoint(x: size.width, y: size.height))
                    p.closeSubpath()
                    ctx.fill(p, with: .color(colors[k].opacity(0.42)))
                }
            }
            .frame(width: 220, height: 64)
            if let showsClipping {
                HStack {
                    clipMark(active: shadowClip > 0.0005, on: showsClipping.wrappedValue, left: true) { showsClipping.wrappedValue.toggle() }
                    Spacer()
                    clipMark(active: highlightClip > 0.0005, on: showsClipping.wrappedValue, left: false) { showsClipping.wrappedValue.toggle() }
                }
                .frame(width: 220)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.42)))
        .fixedSize()
        .allowsHitTesting(showsClipping != nil)
    }

    private func clipMark(active: Bool, on: Bool, left: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: left ? "arrowtriangle.left.fill" : "arrowtriangle.right.fill")
                .font(.system(size: 8))
                .foregroundStyle(active ? (left ? Color(red: 0.4, green: 0.6, blue: 1) : Color(red: 1, green: 0.4, blue: 0.35)) : Theme.tertiary)
                .opacity(on ? 1 : 0.8)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 3).stroke(on ? Theme.secondary : .clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(left ? "Shadow clipping (click to show on the image)" : "Highlight clipping (click to show on the image)")
    }
}
