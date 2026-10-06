import Foundation

/// A saved set of settings, applied to other photos. What it carries depends on its scope; crop and rotation
/// always stay as they are on the photo it is applied to.
public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public enum Scope: String, Codable, CaseIterable, Sendable {
        /// The film look, grain, recipe and Color Chrome — nothing else changes.
        case film
        /// Every adjustment except what belongs to one photo: white balance, exposure, masks and layers stay.
        case look
        /// The whole edit (white balance, exposure, masks and layers too).
        case everything

        public var title: String {
            switch self {
            case .film: return "Film only"
            case .look: return "Look"
            case .everything: return "Everything"
            }
        }
        public var explanation: String {
            switch self {
            case .film: return "Film look, grain, recipe and Color Chrome. Everything else on the photo stays."
            case .look: return "All adjustments. Each photo keeps its crop, white balance, exposure, masks and layers."
            case .everything: return "The whole edit, white balance, exposure, masks and layers included (not the crop)."
            }
        }
    }

    public var id = UUID()
    public var name: String
    public var look: EditState
    public var scope: Scope = .look
    public var builtIn = false

    public init(name: String, look: EditState, scope: Scope = .look, builtIn: Bool = false) {
        self.name = name
        self.scope = scope
        self.look = scope == .look ? look.lookOnly : look.withoutGeometry
        self.builtIn = builtIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        look = try c.decode(EditState.self, forKey: .look)
        scope = (try? c.decodeIfPresent(Scope.self, forKey: .scope)) ?? .look
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }
}

extension EditState {
    var withoutGeometry: EditState {
        var e = self
        e.geometry = FrameGeometry()
        e.cropAspect = .original
        return e
    }

    /// The edit without what belongs to one photo (see `Preset`).
    public var lookOnly: EditState {
        var e = self
        e.geometry = FrameGeometry()
        e.cropAspect = .original
        e.whiteBalance = nil
        e.light.exposure = 0
        e.masks = []
        e.layers = []
        return e
    }

    /// This edit with a preset applied (see `Preset.Scope`).
    public func applying(_ p: Preset) -> EditState {
        switch p.scope {
        case .film:
            var e = self
            e.film = p.look.film
            e.grain = p.look.grain
            e.recipe = p.look.recipe
            e.color.colorChrome = p.look.color.colorChrome
            e.color.colorChromeBlue = p.look.color.colorChromeBlue
            e.enabled.film = p.look.enabled.film
            e.enabled.grain = p.look.enabled.grain
            e.enabled.recipe = p.look.enabled.recipe
            return e
        case .everything:
            var e = p.look
            e.geometry = geometry
            e.cropAspect = cropAspect
            return e
        case .look:
            break
        }
        var e = p.look
        e.geometry = geometry
        e.cropAspect = cropAspect
        e.whiteBalance = whiteBalance
        e.light.exposure = light.exposure
        e.masks = masks
        e.layers = layers
        e.enabled.whiteBalance = enabled.whiteBalance
        e.enabled.masks = enabled.masks
        e.enabled.layers = enabled.layers
        return e
    }
}

/// The presets: a few starters, then the user's own (saved in Application Support/Positives/Presets.json).
public final class PresetStore: @unchecked Sendable {
    public static let shared = PresetStore()

    public private(set) var user: [Preset] = []
    public var all: [Preset] { Self.builtIn + user }
    private let url: URL?
    private let lock = NSLock()

    public init(url: URL? = PresetStore.defaultURL) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode([Preset].self, from: d) { user = p }
    }

    public static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Positives/Presets.json")
    }

    @discardableResult
    public func add(name: String, look: EditState, scope: Preset.Scope = .look) -> Preset {
        let p = Preset(name: name, look: look, scope: scope)
        lock.withLock { user.append(p) }
        save()
        return p
    }

    public func rename(_ id: UUID, to name: String) {
        lock.withLock { if let i = user.firstIndex(where: { $0.id == id }) { user[i].name = name } }
        save()
    }

    public func remove(_ id: UUID) {
        lock.withLock { user.removeAll { $0.id == id } }
        save()
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(lock.withLock { user }) { try? d.write(to: url, options: .atomic) }
    }

    /// Starting points built from the film looks and the recipe.
    public static let builtIn: [Preset] = {
        func make(_ name: String, _ body: (inout EditState) -> Void) -> Preset {
            var e = EditState()
            body(&e)
            var p = Preset(name: name, look: e, builtIn: true)
            p.id = stableID(name)          // the same on every launch
            return p
        }
        return [
            make("Portra Portrait") { e in
                e.film.stock = "kodak_portra_400"; e.grain.amount = 60; e.light.shadows = 10; e.light.highlights = -15
            },
            make("Golden Hour Gold") { e in
                e.film.stock = "kodak_gold_200"; e.film.warmth = 15; e.grain.amount = 70; e.effects.vignette.amount = -15
            },
            make("Kodachrome Travel") { e in
                e.film.stock = "kodak_kodachrome_64"; e.grain.amount = 45; e.effects.vignette.amount = -12
            },
            make("CineStill Night") { e in
                e.film.stock = "kodak_vision3_500t"; e.film.halation = 130; e.grain.amount = 80
                e.effects.bloom.amount = 25; e.light.blacks = -8
            },
            make("Fuji Recipe Chrome") { e in
                e.film.stock = "fujifilm_provia_100f"; e.recipe.dynamicRange = 400; e.recipe.highlight = -1; e.recipe.shadow = 1
                e.color.colorChrome = 100; e.color.colorChromeBlue = 50; e.recipe.redShift = 2; e.recipe.blueShift = -4
                e.recipe.color = -2; e.grain.amount = 60
            },
            make("HP5 Red Filter") { e in
                e.film.stock = "ilford_hp5_plus"; e.film.bwFilter = .red; e.grain.amount = 90; e.light.contrast = 10
            },
            make("Tri-X Street") { e in
                e.film.stock = "kodak_trix_400"; e.film.variant = 1; e.grain.amount = 110; e.effects.vignette.amount = -20
            },
            make("Soft Matte") { e in
                e.curves.master = [CurvePoint(0, 0.06), CurvePoint(0.25, 0.25), CurvePoint(0.75, 0.76), CurvePoint(1, 0.96)]
                e.color.saturation = -12; e.light.contrast = -10; e.grain.amount = 40
            },
        ]
    }()

    /// A UUID derived from a name (FNV-1a), the same on every launch.
    static func stableID(_ name: String) -> UUID {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", h & 0xffffffffffff)) ?? UUID()
    }
}
