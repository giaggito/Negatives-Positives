import CoreGraphics
import Foundation

/// Everything the user has done to one photograph. A plain value: the whole edit is re-applied to the
/// original pixels on every render (non-destructive), kept in the archive when saved, and every undo step is a
/// copy of this struct.
///
/// Slider values follow photo-editor conventions: −100…+100 for most controls, stops for exposure.
/// Decoding is tolerant: fields missing from an older sidecar take their neutral defaults.
public struct EditState: Codable, Equatable, Sendable {
    public var formatVersion = 2

    public var geometry = FrameGeometry()
    /// Crop aspect constraint used by the crop tool.
    public var cropAspect: CropAspect = .original

    /// Nil = the camera's "as shot" white balance (RAF) or unchanged (other files).
    public var whiteBalance: WhiteBalance?
    public var light = Light()
    public var presence = Presence()
    /// Nil = the default for the file type (Standard for RAF, Original for everything else).
    public var profile: ToneProfile?
    public var color = BasicColor()
    public var curves = ToneCurves()
    public var mixer = ColorMixer()
    public var targeted: [TargetedColor] = []
    public var grading = ColorGrading()
    public var film = FilmSettings()
    /// Fujifilm-style recipe settings (with any film or none).
    public var recipe = FilmRecipe()
    public var grain = GrainSettings()
    public var effects = Effects()
    /// Masks with their own adjustments (local adjustments), applied in order.
    public var masks: [LocalAdjustment] = []
    /// Other photographs laid over this one (double exposure), bottom to top.
    public var layers: [PhotoLayer] = []

    public var enabled = Sections()

    public init() {}

    public struct Light: Codable, Equatable, Sendable {
        /// Stops.
        public var exposure: Double = 0
        public var contrast: Double = 0
        public var highlights: Double = 0
        public var shadows: Double = 0
        public var whites: Double = 0
        public var blacks: Double = 0
        public init() {}
        public var isNeutral: Bool { self == Light() }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
            contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
            highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
            blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        }
    }

    /// Local contrast: texture, clarity, dehaze.
    public struct Presence: Codable, Equatable, Sendable {
        public var clarity: Double = 0
        public var texture: Double = 0
        public var dehaze: Double = 0
        public init() {}
        public var isNeutral: Bool { self == Presence() }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
            texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? 0
            dehaze = try c.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        }
    }

    public struct BasicColor: Codable, Equatable, Sendable {
        public var vibrance: Double = 0
        public var saturation: Double = 0
        /// Fujifilm-style Color Chrome Effect and Color Chrome FX Blue: 0 off, 50 weak, 100 strong.
        public var colorChrome: Double = 0
        public var colorChromeBlue: Double = 0
        public init() {}
        public var isNeutral: Bool { self == BasicColor() }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
            saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
            colorChrome = try c.decodeIfPresent(Double.self, forKey: .colorChrome) ?? 0
            colorChromeBlue = try c.decodeIfPresent(Double.self, forKey: .colorChromeBlue) ?? 0
        }
    }

    /// Per-section on/off switches (an off section behaves exactly as if all its sliders were at zero).
    public struct Sections: Codable, Equatable, Sendable {
        public var whiteBalance = true
        public var light = true
        public var presence = true
        public var color = true
        public var curves = true
        public var mixer = true
        public var targeted = true
        public var grading = true
        public var film = true
        public var grain = true
        public var bloom = true
        public var vignette = true
        public var masks = true
        public var recipe = true
        public var layers = true
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            whiteBalance = try c.decodeIfPresent(Bool.self, forKey: .whiteBalance) ?? true
            light = try c.decodeIfPresent(Bool.self, forKey: .light) ?? true
            presence = try c.decodeIfPresent(Bool.self, forKey: .presence) ?? true
            color = try c.decodeIfPresent(Bool.self, forKey: .color) ?? true
            curves = try c.decodeIfPresent(Bool.self, forKey: .curves) ?? true
            mixer = try c.decodeIfPresent(Bool.self, forKey: .mixer) ?? true
            targeted = try c.decodeIfPresent(Bool.self, forKey: .targeted) ?? true
            grading = try c.decodeIfPresent(Bool.self, forKey: .grading) ?? true
            film = try c.decodeIfPresent(Bool.self, forKey: .film) ?? true
            grain = try c.decodeIfPresent(Bool.self, forKey: .grain) ?? true
            bloom = try c.decodeIfPresent(Bool.self, forKey: .bloom) ?? true
            vignette = try c.decodeIfPresent(Bool.self, forKey: .vignette) ?? true
            masks = try c.decodeIfPresent(Bool.self, forKey: .masks) ?? true
            recipe = try c.decodeIfPresent(Bool.self, forKey: .recipe) ?? true
            layers = try c.decodeIfPresent(Bool.self, forKey: .layers) ?? true
        }
    }

    /// The edit with sections that are switched off neutralised.
    public var effective: EditState {
        var e = self
        if !enabled.whiteBalance { e.whiteBalance = nil }
        if !enabled.light { e.light = Light() }
        if !enabled.presence { e.presence = Presence() }
        if !enabled.color { e.color = BasicColor() }
        if !enabled.curves { e.curves = ToneCurves() }
        if !enabled.mixer { e.mixer = ColorMixer() }
        if !enabled.targeted { e.targeted = [] }
        if !enabled.grading { e.grading = ColorGrading() }
        if !enabled.film { e.film.stock = nil }
        if !enabled.grain { e.grain.amount = 0 }
        if !enabled.recipe { e.recipe = FilmRecipe(); e.color.colorChrome = 0; e.color.colorChromeBlue = 0 }
        if !enabled.bloom { e.effects.bloom.amount = 0 }
        if !enabled.vignette { e.effects.vignette.amount = 0 }
        e.masks = enabled.masks ? e.masks.filter { $0.enabled && !$0.components.isEmpty } : []
        e.targeted = e.targeted.filter(\.enabled)
        e.layers = enabled.layers ? Array(e.layers.filter { $0.enabled && $0.amount > 0 }.prefix(PhotoLayer.maximumCount)) : []
        for i in e.layers.indices where !e.layers[i].mask.enabled { e.layers[i].mask.components = [] }
        return e
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, geometry, cropAspect, whiteBalance, light, presence, profile, color, curves, mixer, targeted, grading, film, recipe, grain, effects, masks, layers, enabled
    }


    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = 2
        geometry = try c.decodeIfPresent(FrameGeometry.self, forKey: .geometry) ?? FrameGeometry()
        cropAspect = (try? c.decodeIfPresent(CropAspect.self, forKey: .cropAspect)) ?? .original
        whiteBalance = try c.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance)
        light = try c.decodeIfPresent(Light.self, forKey: .light) ?? Light()
        presence = try c.decodeIfPresent(Presence.self, forKey: .presence) ?? Presence()
        profile = (try? c.decodeIfPresent(ToneProfile.self, forKey: .profile)) ?? nil
        color = try c.decodeIfPresent(BasicColor.self, forKey: .color) ?? BasicColor()
        curves = try c.decodeIfPresent(ToneCurves.self, forKey: .curves) ?? ToneCurves()
        mixer = try c.decodeIfPresent(ColorMixer.self, forKey: .mixer) ?? ColorMixer()
        targeted = try c.decodeIfPresent([TargetedColor].self, forKey: .targeted) ?? []
        grading = try c.decodeIfPresent(ColorGrading.self, forKey: .grading) ?? ColorGrading()
        film = try c.decodeIfPresent(FilmSettings.self, forKey: .film) ?? FilmSettings()
        recipe = try c.decodeIfPresent(FilmRecipe.self, forKey: .recipe) ?? FilmRecipe()
        grain = try c.decodeIfPresent(GrainSettings.self, forKey: .grain) ?? GrainSettings()
        effects = try c.decodeIfPresent(Effects.self, forKey: .effects) ?? Effects()
        masks = try c.decodeIfPresent([LocalAdjustment].self, forKey: .masks) ?? []
        layers = try c.decodeIfPresent([PhotoLayer].self, forKey: .layers) ?? []
        enabled = try c.decodeIfPresent(Sections.self, forKey: .enabled) ?? Sections()
    }
}

/// How scene light becomes a picture before any adjustment.
public enum ToneProfile: String, Codable, CaseIterable, Sendable {
    /// Photographic S-curve, highlights roll off softly (RAF default).
    case standard
    /// Flatter, more highlight and shadow room, for heavy grading.
    case flat
    /// No curve: scene-linear values are shown as they are (clips above white).
    case linear
    /// The file's own rendering, untouched (default for JPEG / HEIC / PNG / TIFF).
    case original

    public var displayName: String {
        switch self {
        case .standard: return "Standard"
        case .flat: return "Flat"
        case .linear: return "Linear"
        case .original: return "Original"
        }
    }
}

public enum CropAspect: String, Codable, CaseIterable, Sendable {
    case free, original, square, fourFive, threeTwo, sixteenNine, panoramic

    public var displayName: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .fourFive: return "4:5"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .panoramic: return "65:24"
        }
    }

    /// Width / height of the long side over the short side (orientation follows the current crop), or nil (free).
    public func ratio(original: Double) -> Double? {
        switch self {
        case .free: return nil
        case .original: return max(original, 1 / original)
        case .square: return 1
        case .fourFive: return 5.0 / 4
        case .threeTwo: return 1.5
        case .sixteenNine: return 16.0 / 9
        case .panoramic: return 65.0 / 24
        }
    }
}

extension EditState {
    /// A fresh edit for a photo: upright, everything else neutral.
    public static func initial(for source: SourceImage) -> EditState {
        var e = EditState()
        e.geometry = source.defaultGeometry
        return e
    }
}
