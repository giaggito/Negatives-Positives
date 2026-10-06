import DarkroomUI
import PositivesCore
import SwiftUI

/// Film category: a browser of film looks previewed on the photo itself, the chosen film's options, and grain.
struct FilmPanel: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }
    private var look: FilmLook? { FilmLooks.shared.look(model.edit.film.stock) }

    static let tabs: [(String, [FilmLook.Kind])] = [("Color", [.colorNegative]), ("Slide", [.slide]), ("B&W", [.blackAndWhite]),
                                                     ("More", [.cinema, .instant])]

    var body: some View {
        InspectorSection(title: "Film", icon: "film", isEnabled: kit.enabled(\.film, "Film"), isExpanded: kit.expanded("film"),
                         isModified: model.edit.film != FilmSettings(),
                         onReset: { model.change("Reset film") { $0.film = FilmSettings() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                Segmented(options: Self.tabs.map(\.0), selection: $model.filmTab)
                browser
                if let look { details(look) }
            }
        }
        .onAppear {
            if let look, let i = Self.tabs.firstIndex(where: { $0.1.contains(look.kind) }) { model.filmTab = i }
            model.refreshFilmPreviews()
        }
        .onChange(of: model.historyIndex) { _, _ in model.refreshFilmPreviews() }
        .onChange(of: model.source?.url) { _, _ in model.refreshFilmPreviews() }
        RecipeSection(model: model)
        GrainSection(model: model)
        HStack(spacing: 8) {
            PlainTextButton(title: "Save as film preset…", symbol: "square.and.arrow.down") {
                NotificationCenter.default.post(name: .savePreset, object: Preset.Scope.film)
            }
            .help("Keep this film, recipe and grain as a preset to use on other photos (Presets, P)")
            PlainTextButton(title: "Presets", symbol: "camera.filters") { NotificationCenter.default.post(name: .showPresets, object: nil) }
        }
    }

    private var browser: some View {
        let kinds = Self.tabs[min(model.filmTab, Self.tabs.count - 1)].1
        let looks = FilmLooks.shared.looks.filter { kinds.contains($0.kind) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 6) {
            FilmTile(title: "No film", image: model.filmPreviews[""], selected: model.edit.film.stock == nil) { model.setFilm(nil) }
            ForEach(looks) { l in
                FilmTile(title: l.shortName, image: model.filmPreviews[l.id], selected: look?.id == l.id) { model.setFilm(l.id) }
                    .help(l.name)
            }
        }
    }

    @ViewBuilder
    private func details(_ look: FilmLook) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(look.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            Text(look.note).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        if look.availableVariants.count > 1 {
            HStack(spacing: 10) {
                Text("Lab variant").font(Theme.label).foregroundStyle(Theme.secondary)
                Segmented(options: look.availableVariants.map(FilmLook.variantName), selection: Binding(
                    get: { look.availableVariants.firstIndex(of: model.edit.film.variant) ?? 1 },
                    set: { i in
                        let v = look.availableVariants[i]
                        model.change("Variant \(FilmLook.variantName(v))") { $0.film.variant = v }
                    }))
            }
            .help("The collection's variations of this film: − is cleaner and crisper, + and ++ are softer and more faded.")
        }
        if look.isBlackAndWhite {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lens filter").font(Theme.label).foregroundStyle(Theme.secondary)
                Segmented(options: BWFilter.allCases.map(\.title), selection: Binding(
                    get: { BWFilter.allCases.firstIndex(of: model.edit.film.bwFilter) ?? 0 },
                    set: { i in model.change("\(BWFilter.allCases[i].title) filter") { $0.film.bwFilter = BWFilter.allCases[i] } }))
                Text(filterNote(model.edit.film.bwFilter))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
        kit.slider("Intensity", \.film.intensity, range: 0...100, defaultValue: 100, format: { String(format: "%.0f%%", $0) })
        if !look.isBlackAndWhite {
            kit.slider("Warmth", \.film.warmth, gradient: [Color(red: 0.4, green: 0.6, blue: 1), Color(white: 0.8), Color(red: 1, green: 0.8, blue: 0.35)])
            kit.slider("Tint", \.film.tint, gradient: [Color(red: 0.4, green: 0.8, blue: 0.45), Color(white: 0.8), Color(red: 0.9, green: 0.45, blue: 0.85)])
        }
        if look.halation.max() > 0.015 {
            kit.slider("Halation", \.film.halation, range: 0...300, defaultValue: 100, format: { String(format: "%.0f%%", $0) },
                       gradient: [Color(white: 0.4), Color(red: 1, green: 0.35, blue: 0.2)])
        }
        Text(look.creditLine)
            .font(.system(size: 10)).foregroundStyle(Theme.tertiary.opacity(0.8)).fixedSize(horizontal: false, vertical: true)
    }
}

private func filterNote(_ f: BWFilter) -> String {
    switch f {
    case .none: return "Coloured filters change how colours turn into greys, as on a black & white camera."
    case .yellow: return "Yellow: slightly darker sky, clouds stand out — the classic everyday filter."
    case .orange: return "Orange: darker sky, more contrast, smoother skin."
    case .red: return "Red: the bluer the sky, the darker it turns — deep blue goes near-black, clouds pop, haze is cut. Pale skies change less."
    case .green: return "Green: lighter foliage, natural skin tones, darker reds."
    case .blue: return "Blue: darker reds and skin, more haze and atmosphere."
    }
}

/// Fujifilm-style recipe: the settings photographers combine with a film simulation, laid out like the
/// camera's menu.
struct RecipeSection: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        InspectorSection(title: "Recipe", icon: "list.bullet.rectangle", isEnabled: kit.enabled(\.recipe, "Recipe"), isExpanded: kit.expanded("recipe"),
                         isModified: !model.edit.recipe.isNeutral || model.edit.color.colorChrome != 0 || model.edit.color.colorChromeBlue != 0,
                         onReset: { model.change("Reset recipe") { $0.recipe = FilmRecipe(); $0.color.colorChrome = 0; $0.color.colorChromeBlue = 0 } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                row("Dynamic range") {
                    Segmented(options: ["DR100", "DR200", "DR400"], selection: Binding(
                        get: { [100, 200, 400].firstIndex(of: model.edit.recipe.dynamicRange) ?? 0 },
                        set: { i in model.change("DR\([100, 200, 400][i])") { $0.recipe.dynamicRange = [100, 200, 400][i] } }))
                }
                .help("DR200 / DR400 keep one / two more stops of detail in the highlights")
                row("Color Chrome") { strength(\.color.colorChrome, "Color Chrome") }
                    .help("Deeper, richer tones in strongly saturated colours")
                row("Color Chrome Blue") { strength(\.color.colorChromeBlue, "Color Chrome Blue") }
                    .help("Deeper, richer blues — skies and water")
                row("Grain effect") {
                    HStack(spacing: 6) {
                        Segmented(options: ["Off", "Weak", "Strong"], selection: Binding(
                            get: { let a = model.edit.grain.amount; return a <= 0 ? 0 : (a <= 80 ? 1 : 2) },
                            set: { i in model.change("Grain effect") { $0.grain.amount = [0, 60, 120][i] } }))
                        Segmented(options: ["Small", "Large"], selection: Binding(
                            get: { model.edit.grain.size > 115 ? 1 : 0 },
                            set: { i in model.change("Grain size") { $0.grain.size = i == 1 ? 160 : 100 } }))
                            .frame(width: 92)
                    }
                }
                step("WB shift red", \.recipe.redShift, -9...9, 1, gradient: [Color(red: 0.3, green: 0.75, blue: 0.75), Color(white: 0.8), Color(red: 0.95, green: 0.35, blue: 0.3)])
                step("WB shift blue", \.recipe.blueShift, -9...9, 1, gradient: [Color(red: 0.95, green: 0.85, blue: 0.3), Color(white: 0.8), Color(red: 0.3, green: 0.5, blue: 1)])
                step("Highlight", \.recipe.highlight, -2...4, 0.5)
                step("Shadow", \.recipe.shadow, -2...4, 0.5)
                step("Color", \.recipe.color, -4...4, 1)
                step("Clarity", \.recipe.clarity, -5...5, 1)
                Text("White balance and its temperature are in Color; the photo's own exposure and tone stay in Light.")
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary)
            content()
        }
    }

    private func strength(_ kp: WritableKeyPath<EditState, Double>, _ title: String) -> some View {
        Segmented(options: ["Off", "Weak", "Strong"], selection: Binding(
            get: { let v = model.edit[keyPath: kp]; return v <= 0 ? 0 : (v <= 50 ? 1 : 2) },
            set: { i in model.change("\(title) \(["off", "weak", "strong"][i])") { $0[keyPath: kp] = [0, 50, 100][i] } }))
    }

    /// A stepped slider (camera-style values: −2, −1.5 … +4).
    private func step(_ title: String, _ kp: WritableKeyPath<EditState, Double>, _ range: ClosedRange<Double>, _ step: Double,
                      gradient: [Color]? = nil) -> some View {
        ParameterSlider(title: title,
                        value: Binding(get: { model.edit[keyPath: kp] },
                                       set: { v in model.change(title) { $0[keyPath: kp] = (v / step).rounded() * step } }),
                        range: range, defaultValue: 0,
                        format: { v in v == 0 ? "0" : (step < 1 ? String(format: "%+.1f", v) : String(format: "%+.0f", v)) },
                        centreMark: true, gradient: gradient, onEditingChanged: kit.editing(title))
    }
}

private struct FilmTile: View {
    let title: String
    let image: CGImage?
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    Rectangle().fill(Theme.hairline)
                    if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                }
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Theme.accent : (hover ? Theme.secondary.opacity(0.5) : .clear), lineWidth: selected ? 2 : 1))
                Text(title)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// Grain: how much, how big, and — under "More" — its character.
struct GrainSection: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        let look = model.edit.film.stock != nil ? FilmLooks.shared.look(model.edit.film.stock) : nil
        let preset = GrainPreset.all.first { $0.id == model.edit.grain.preset }
        let character = preset?.character ?? look?.grain ?? GrainPreset.all[1].character
        InspectorSection(title: "Grain", icon: "circle.dotted", isEnabled: kit.enabled(\.grain, "Grain"), isExpanded: kit.expanded("grain"),
                         isModified: model.edit.grain.amount > 0,
                         onReset: { model.change("Reset grain") { e in let seed = e.grain.seed; e.grain = GrainSettings(); e.grain.seed = seed } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                kit.slider("Amount", \.grain.amount, range: 0...200, format: { $0 == 0 ? "Off" : String(format: "%.0f%%", $0) })
                kit.slider("Size", \.grain.size, range: 25...400, defaultValue: 100, format: { String(format: "%.0f%%", $0) })
                VStack(alignment: .leading, spacing: 6) {
                    Text(look != nil ? "Grain type — the film's own, or a film speed (ISO)" : "Grain type — film speed (ISO)")
                        .font(Theme.label).foregroundStyle(Theme.secondary)
                    let options = (look != nil ? ["Film's"] : []) + GrainPreset.all.map(\.shortName)
                    let ids: [String?] = (look != nil ? [nil] : []) + GrainPreset.all.map(\.id)
                    Segmented(options: options, selection: Binding(
                        get: { ids.firstIndex(of: model.edit.grain.preset) ?? (look != nil ? 0 : 1) },
                        set: { i in model.change("Grain type") { $0.grain.preset = ids[i] } }))
                        .help("The grain of the chosen film, or a typical grain for a film speed.")
                }
                HStack {
                    PlainTextButton(title: "View at 100%", symbol: "1.magnifyingglass") { model.zoom(1) }
                        .help("Grain is only judged properly at 100% (⌘1)")
                    Spacer()
                    PlainTextButton(title: model.expanded.contains("grainMore") ? "Less" : "More", symbol: "slider.horizontal.3") {
                        if model.expanded.contains("grainMore") { model.expanded.remove("grainMore") } else { model.expanded.insert("grainMore") }
                    }
                }
                if model.expanded.contains("grainMore") {
                    ParameterSlider(title: "Clumping",
                                    value: Binding(get: { model.edit.grain.roughness ?? character.roughness * 100 },
                                                   set: { v in model.change("Clumping") { $0.grain.roughness = v.rounded() } }),
                                    range: 0...100, defaultValue: character.roughness * 100, format: { String(format: "%.0f", $0) },
                                    onEditingChanged: kit.editing("Clumping"))
                        .help("Smooth, even grain ↔ irregular clumps")
                    if look?.isBlackAndWhite != true {
                        ParameterSlider(title: "Color",
                                        value: Binding(get: { model.edit.grain.colour ?? character.colour * 100 },
                                                       set: { v in model.change("Grain color") { $0.grain.colour = v.rounded() } }),
                                        range: 0...100, defaultValue: character.colour * 100, format: { String(format: "%.0f", $0) },
                                        gradient: [Color(white: 0.6), Color(red: 0.9, green: 0.4, blue: 0.5)],
                                        onEditingChanged: kit.editing("Grain color"))
                            .help("Monochrome grain ↔ independent grain in each colour layer")
                    }
                    kit.slider("Film softness", \.grain.softness, range: 0...100, defaultValue: 50, format: { String(format: "%.0f", $0) })
                        .help("Softens the picture under the grain the way light spreads in an emulsion")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Film format").font(Theme.label).foregroundStyle(Theme.secondary)
                        Segmented(options: FilmFormat.allCases.map(\.displayName), selection: Binding(
                            get: { FilmFormat.allCases.firstIndex(of: model.edit.grain.format) ?? 0 },
                            set: { i in model.change("Film format") { $0.grain.format = FilmFormat.allCases[i] } }))
                        Text("A bigger negative makes the same grain smaller in the picture.")
                            .font(.system(size: 10)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    PlainTextButton(title: "New grain pattern", symbol: "dice") { model.change("New grain pattern") { $0.grain.seed &+= 1 } }
                }
            }
        }
    }
}

/// Effects category: bloom (light spilling around bright areas) and vignette.
struct EffectsPanel: View {
    @Bindable var model: EditorModel
    private var kit: PanelKit { PanelKit(model: model) }

    var body: some View {
        InspectorSection(title: "Bloom", icon: "sun.haze", isEnabled: kit.enabled(\.bloom, "Bloom"), isExpanded: kit.expanded("bloom"),
                         isModified: model.edit.effects.bloom != Effects.Bloom(),
                         onReset: { model.change("Reset bloom") { $0.effects.bloom = Effects.Bloom() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                kit.slider("Amount", \.effects.bloom.amount, range: 0...100, format: { String(format: "%.0f", $0) })
                kit.slider("Threshold", \.effects.bloom.threshold, range: -2...5, defaultValue: 2, step: 0.1, format: { String(format: "%+.1f EV", $0) })
                kit.slider("Radius", \.effects.bloom.radius, range: 0...100, defaultValue: 30, format: { String(format: "%.0f", $0) })
                kit.slider("Warmth", \.effects.bloom.warmth, defaultValue: 20,
                           gradient: [Color(red: 0.4, green: 0.6, blue: 1), Color(white: 0.8), Color(red: 1, green: 0.7, blue: 0.35)])
            }
        }
        InspectorSection(title: "Vignette", icon: "circle.dashed", isEnabled: kit.enabled(\.vignette, "Vignette"), isExpanded: kit.expanded("vignette"),
                         isModified: model.edit.effects.vignette != Effects.Vignette(),
                         onReset: { model.change("Reset vignette") { $0.effects.vignette = Effects.Vignette() } }) {
            VStack(alignment: .leading, spacing: Theme.sectionSpacing) {
                kit.slider("Amount", \.effects.vignette.amount)
                kit.slider("Midpoint", \.effects.vignette.midpoint, range: 0...100, defaultValue: 50, format: { String(format: "%.0f", $0) })
                kit.slider("Roundness", \.effects.vignette.roundness)
                kit.slider("Feather", \.effects.vignette.feather, range: 0...100, defaultValue: 50, format: { String(format: "%.0f", $0) })
                kit.slider("Highlights", \.effects.vignette.highlights, range: 0...100, format: { String(format: "%.0f", $0) })
            }
        }
    }
}
