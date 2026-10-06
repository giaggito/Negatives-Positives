import Foundation

/// A point on a tone curve, both coordinates in perceptual units 0…1 (input → output).
public struct CurvePoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// Point curves: a master curve on all channels (hue-preserving) and one per channel (R, G, B, which do
/// shift colours, as in a darkroom's colour filtration).
public struct ToneCurves: Codable, Equatable, Sendable {
    public static let identity = [CurvePoint(0, 0), CurvePoint(1, 1)]
    public var master = ToneCurves.identity
    public var red = ToneCurves.identity
    public var green = ToneCurves.identity
    public var blue = ToneCurves.identity
    public init() {}

    public enum Channel: Int, CaseIterable, Sendable { case master, red, green, blue }

    public subscript(_ c: Channel) -> [CurvePoint] {
        get { switch c { case .master: master; case .red: red; case .green: green; case .blue: blue } }
        set { switch c { case .master: master = newValue; case .red: red = newValue; case .green: green = newValue; case .blue: blue = newValue } }
    }

    public var isNeutral: Bool { masterIsIdentity && rgbIsIdentity }
    public var masterIsIdentity: Bool { CurveMath.isIdentity(master) }
    public var rgbIsIdentity: Bool { CurveMath.isIdentity(red) && CurveMath.isIdentity(green) && CurveMath.isIdentity(blue) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent([CurvePoint].self, forKey: .master) ?? Self.identity
        red = try c.decodeIfPresent([CurvePoint].self, forKey: .red) ?? Self.identity
        green = try c.decodeIfPresent([CurvePoint].self, forKey: .green) ?? Self.identity
        blue = try c.decodeIfPresent([CurvePoint].self, forKey: .blue) ?? Self.identity
    }
}

/// Hue / saturation / luminance for eight colour ranges, −100…+100 each.
public struct ColorMixer: Codable, Equatable, Sendable {
    public static let names = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    public var hue = [Double](repeating: 0, count: 8)
    public var saturation = [Double](repeating: 0, count: 8)
    public var luminance = [Double](repeating: 0, count: 8)
    public init() {}
    public var isNeutral: Bool { self == ColorMixer() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func eight(_ k: CodingKeys) throws -> [Double] {
            let v = try c.decodeIfPresent([Double].self, forKey: k) ?? []
            return v.count == 8 ? v : [Double](repeating: 0, count: 8)
        }
        hue = try eight(.hue); saturation = try eight(.saturation); luminance = try eight(.luminance)
    }
}

/// A colour range picked on the photo, adjusted on its own.
public struct TargetedColor: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    /// Picked colour in OKLCh: hue in degrees, chroma, lightness.
    public var hue: Double
    public var chroma: Double
    public var lightness: Double
    /// Half-width of the hue range in degrees, and how gradually it fades out (0…100).
    public var width: Double = 25
    public var softness: Double = 50
    public var hueShift: Double = 0
    public var saturation: Double = 0
    public var luminance: Double = 0
    /// 0…100: desaturate everything outside the range (100 = only this colour stays in colour).
    public var isolate: Double = 0
    public var enabled = true

    public init(hue: Double, chroma: Double, lightness: Double) {
        self.hue = hue
        self.chroma = chroma
        self.lightness = lightness
    }

    public static let maximumCount = 4
}

/// Colour grading in three tonal zones plus an overall tint.
public struct ColorGrading: Codable, Equatable, Sendable {
    public struct Wheel: Codable, Equatable, Sendable {
        /// Direction of the tint in OKLab hue degrees, its strength 0…100, and a luminance offset −100…+100.
        public var hue: Double = 0
        public var saturation: Double = 0
        public var luminance: Double = 0
        public init() {}
        public var isNeutral: Bool { saturation == 0 && luminance == 0 }
    }

    public var shadows = Wheel()
    public var midtones = Wheel()
    public var highlights = Wheel()
    public var global = Wheel()
    /// −100…+100: moves the split between shadows and highlights.
    public var balance: Double = 0
    /// 0…100: how much the zones overlap.
    public var blending: Double = 50
    public init() {}
    public var isNeutral: Bool { shadows.isNeutral && midtones.isNeutral && highlights.isNeutral && global.isNeutral }
}
