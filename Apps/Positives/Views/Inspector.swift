import DarkroomUI
import PositivesCore
import SwiftUI

/// The right-hand panel: a bar of categories (like the sections of Photos' Adjust panel) and the tools of
/// the chosen category, so no list ever gets long.
struct Inspector: View {
    @Bindable var model: EditorModel
    @Binding var showExport: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            CategoryBar(model: model)
                .padding(.horizontal, 6).padding(.bottom, 8)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            Group {
                switch model.category {
                case .history:
                    HistoryList(model: model)
                default:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            switch model.category {
                            case .light: LightPanel(model: model)
                            case .color: ColorPanel(model: model)
                            case .curves: CurvesPanel(model: model)
                            case .film: FilmPanel(model: model)
                            case .effects: EffectsPanel(model: model)
                            case .masks: MaskPanel(model: model)
                            case .layers: LayerPanel(model: model)
                            case .history: EmptyView()
                            }
                        }
                        .padding(18)
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxHeight: .infinity)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            HStack(spacing: 8) {
                PlainTextButton(title: "Reset", symbol: "arrow.uturn.backward") { model.resetAll() }
                    .help("Reset all adjustments (⇧⌘R)")
                PlainTextButton(title: "Export…", symbol: "square.and.arrow.up", prominent: true) { showExport = true }
            }
            .padding(14)
        }
        .frame(width: Theme.inspectorWidth)
        .background(Theme.panel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.source?.url.lastPathComponent ?? "").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
            if let s = model.source {
                let size = model.displaySize
                Text("\(s.cameraDescription.isEmpty ? (s.kind == .raw ? "RAW" : "\(s.bitsPerComponent)-bit") : s.cameraDescription) · \(Int(size.width))×\(Int(size.height))")
                    .font(Theme.value).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CategoryBar: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorCategory.allCases) { c in
                CategoryButton(category: c, selected: model.category == c, modified: isModified(c)) {
                    withAnimation(.easeInOut(duration: 0.12)) { model.category = c }
                }
            }
        }
    }

    private func isModified(_ c: InspectorCategory) -> Bool {
        let e = model.edit
        switch c {
        case .light: return !e.light.isNeutral || !e.presence.isNeutral || e.profile != nil
        case .color: return e.whiteBalance != nil || !e.color.isNeutral || !e.mixer.isNeutral || !e.targeted.isEmpty || !e.grading.isNeutral
        case .curves: return !e.curves.isNeutral
        case .film: return e.film.stock != nil || e.grain.amount > 0 || !e.recipe.isNeutral || e.color.colorChrome != 0 || e.color.colorChromeBlue != 0
        case .effects: return !e.effects.isNeutral
        case .masks: return !e.masks.isEmpty
        case .layers: return !e.layers.isEmpty
        case .history: return false
        }
    }
}

private struct CategoryButton: View {
    let category: InspectorCategory
    let selected: Bool
    let modified: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: category.symbol).font(.system(size: 15, weight: selected ? .semibold : .regular))
                        .frame(width: 26, height: 20)
                    if modified { Circle().fill(Theme.secondary).frame(width: 4, height: 4).offset(x: 2, y: -1) }
                }
                Text(category.title).font(.system(size: 10, weight: selected ? .semibold : .medium))
                    .lineLimit(1).minimumScaleFactor(0.7).allowsTightening(true)
            }
            .foregroundStyle(selected ? Theme.text : (hover ? Theme.secondary : Theme.tertiary))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.hairline : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(category.title)
    }
}

/// Bindings shared by the panels: sliders grouped into one undo step per drag, section switches, folding.
struct PanelKit {
    let model: EditorModel

    func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { model.expanded.contains(key) },
                set: { if $0 { model.expanded.insert(key) } else { model.expanded.remove(key) } })
    }

    func enabled(_ kp: WritableKeyPath<EditState.Sections, Bool>, _ title: String) -> Binding<Bool> {
        Binding(get: { model.edit.enabled[keyPath: kp] }, set: { v in model.change(v ? "\(title) on" : "\(title) off") { $0.enabled[keyPath: kp] = v } })
    }

    func editing(_ title: String) -> (Bool) -> Void {
        { $0 ? model.beginInteraction(title) : model.endInteraction() }
    }

    /// A −100…+100 (or custom) slider bound to the edit.
    func slider(_ title: String, _ kp: WritableKeyPath<EditState, Double>, range: ClosedRange<Double> = -100...100,
                defaultValue: Double = 0, step: Double = 1, format: @escaping (Double) -> String = { String(format: "%+.0f", $0) },
                gradient: [Color]? = nil) -> ParameterSlider {
        ParameterSlider(title: title,
                        value: Binding(get: { model.edit[keyPath: kp] },
                                       set: { v in model.change(title) { $0[keyPath: kp] = (v / step).rounded() * step } }),
                        range: range, defaultValue: defaultValue, format: format, centreMark: true, gradient: gradient,
                        onEditingChanged: editing(title))
    }
}

struct LightPanel: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        InspectorSection(title: "Light", icon: "sun.max", isEnabled: kit.enabled(\.light, "Light"), isExpanded: kit.expanded("light"),
                         isModified: !model.edit.light.isNeutral || model.edit.profile != nil,
                         onReset: { model.change("Reset light") { $0.light = EditState.Light(); $0.profile = nil } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                if let s = model.source, s.availableProfiles.count > 1 {
                    let profiles = s.availableProfiles
                    HStack(spacing: 10) {
                        Text("Profile").font(Theme.label).foregroundStyle(Theme.secondary)
                        Segmented(options: profiles.map(\.displayName), selection: Binding(
                            get: { profiles.firstIndex(of: model.edit.profile ?? s.defaultProfile) ?? 0 },
                            set: { i in model.change("Profile \(profiles[i].displayName)") { $0.profile = profiles[i] == s.defaultProfile ? nil : profiles[i] } }))
                    }
                }
                kit.slider("Exposure", \.light.exposure, range: -5...5, step: 0.01, format: { String(format: "%+.2f EV", $0) })
                kit.slider("Contrast", \.light.contrast)
                kit.slider("Highlights", \.light.highlights)
                kit.slider("Shadows", \.light.shadows)
                kit.slider("Whites", \.light.whites)
                kit.slider("Blacks", \.light.blacks)
            }
        }
        InspectorSection(title: "Presence", icon: "circle.lefthalf.striped.horizontal", isEnabled: kit.enabled(\.presence, "Presence"),
                         isExpanded: kit.expanded("presence"), isModified: !model.edit.presence.isNeutral,
                         onReset: { model.change("Reset presence") { $0.presence = EditState.Presence() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                kit.slider("Texture", \.presence.texture)
                kit.slider("Clarity", \.presence.clarity)
                kit.slider("Dehaze", \.presence.dehaze)
            }
        }
    }
}

struct HistoryList: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.history.enumerated()), id: \.element.id) { i, entry in
                        Button { model.jump(to: i) } label: {
                            HStack {
                                Text(entry.label).font(Theme.label)
                                    .foregroundStyle(i == model.historyIndex ? Color.black : (i > model.historyIndex ? Theme.tertiary : Theme.secondary))
                                Spacer()
                                Text(entry.date, style: .time).font(Theme.value)
                                    .foregroundStyle(i == model.historyIndex ? Color.black.opacity(0.6) : Theme.tertiary)
                            }
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 5).fill(i == model.historyIndex ? Theme.accent : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(entry.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: model.historyIndex) { _, i in
                if model.history.indices.contains(i) { proxy.scrollTo(model.history[i].id) }
            }
        }
    }
}
