import Foundation

/// A point on the photo in sensor coordinates (before flips, turns, straightening and crop) divided by the
/// sensor's long side — so masks stay on the same subject whatever the geometry, and circles stay round.
public struct MaskPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

/// One brush stroke: a polyline painted with a round, feathered tip.
public struct BrushStroke: Codable, Equatable, Sendable {
    public var points: [MaskPoint]
    /// Tip radius as a fraction of the sensor's long side.
    public var radius: Double
    /// 0…100: how soft the tip's edge is.
    public var feather: Double
    /// 0…100: how much one stroke adds (100 = fully on).
    public var flow: Double
    public var erase: Bool
    public init(points: [MaskPoint], radius: Double, feather: Double, flow: Double, erase: Bool) {
        self.points = points; self.radius = radius; self.feather = feather; self.flow = flow; self.erase = erase
    }
}

/// One part of a mask. Parts combine in order: add (union), subtract, intersect.
public struct MaskComponent: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case brush, linear, radial, luminance, color, subject, people, sky
        public var title: String {
            switch self {
            case .brush: return "Brush"
            case .linear: return "Linear gradient"
            case .radial: return "Radial gradient"
            case .luminance: return "Luminance range"
            case .color: return "Color range"
            case .subject: return "Subject"
            case .people: return "People"
            case .sky: return "Sky"
            }
        }
        public var symbol: String {
            switch self {
            case .brush: return "paintbrush.pointed"
            case .linear: return "square.bottomhalf.filled"
            case .radial: return "circle.circle"
            case .luminance: return "circle.lefthalf.filled"
            case .color: return "eyedropper"
            case .subject: return "person.and.background.dotted"
            case .people: return "person.2"
            case .sky: return "cloud.sun"
            }
        }
        /// Kinds read from a picture made by Vision (person / subject segmentation).
        public var isDetected: Bool { self == .subject || self == .people || self == .sky }
    }
    public enum Mode: String, Codable, Sendable { case add, subtract, intersect }

    public var id = UUID()
    public var kind: Kind
    public var mode: Mode = .add
    public var invert = false
    /// Brush strokes.
    public var strokes: [BrushStroke] = []
    /// Linear gradient: fully selected before `start`, not at all after `end`.
    public var start = MaskPoint(0.5, 0.15)
    public var end = MaskPoint(0.5, 0.4)
    /// Radial gradient: ellipse centre, half-axes (fractions of the long side), rotation (degrees), and how far
    /// inside the edge it starts fading (0…100). Inside is selected.
    public var center = MaskPoint(0.5, 0.33)
    public var radiusX = 0.18
    public var radiusY = 0.12
    public var angle = 0.0
    public var feather = 50.0
    /// Luminance range (0…100 lightness) and the softness of its edges.
    public var low = 60.0
    public var high = 100.0
    public var smoothness = 25.0
    /// Colour range: a picked colour (OKLCh: hue in degrees, chroma, lightness) and how wide the range is.
    public var hue = 250.0
    public var chroma = 0.08
    public var lightness = 0.65
    public var range = 30.0

    public init(kind: Kind) { self.kind = kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .brush
        mode = (try? c.decodeIfPresent(Mode.self, forKey: .mode)) ?? .add
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        strokes = try c.decodeIfPresent([BrushStroke].self, forKey: .strokes) ?? []
        let d = MaskComponent(kind: kind)
        start = try c.decodeIfPresent(MaskPoint.self, forKey: .start) ?? d.start
        end = try c.decodeIfPresent(MaskPoint.self, forKey: .end) ?? d.end
        center = try c.decodeIfPresent(MaskPoint.self, forKey: .center) ?? d.center
        radiusX = try c.decodeIfPresent(Double.self, forKey: .radiusX) ?? d.radiusX
        radiusY = try c.decodeIfPresent(Double.self, forKey: .radiusY) ?? d.radiusY
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? d.feather
        low = try c.decodeIfPresent(Double.self, forKey: .low) ?? d.low
        high = try c.decodeIfPresent(Double.self, forKey: .high) ?? d.high
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness) ?? d.smoothness
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? d.hue
        chroma = try c.decodeIfPresent(Double.self, forKey: .chroma) ?? d.chroma
        lightness = try c.decodeIfPresent(Double.self, forKey: .lightness) ?? d.lightness
        range = try c.decodeIfPresent(Double.self, forKey: .range) ?? d.range
    }
}

/// What a mask changes, applied in proportion to how selected each pixel is, at the matching stage of the
/// pipeline (white balance and exposure in scene light, contrast and curve in the tone stage, saturation and
/// colour in the colour stage, grain where grain is made).
public struct LocalSettings: Codable, Equatable, Sendable {
    public var exposure: Double = 0          // EV, −4…4
    public var contrast: Double = 0          // −100…100
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var temperature: Double = 0       // −100 (cooler) … 100 (warmer)
    public var tint: Double = 0              // −100 (green) … 100 (magenta)
    public var saturation: Double = 0
    /// A colour cast laid over the selection: hue (degrees) and strength (0…100).
    public var colorHue: Double = 40
    public var colorAmount: Double = 0
    /// Master tone curve of the selection (perceptual units, like the global one).
    public var curve: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(1, 1)]
    /// −100 (no grain here) … +100 (twice the grain).
    public var grain: Double = 0
    public init() {}

    public var isNeutral: Bool { self == LocalSettings() }
    public var curveIsIdentity: Bool { curve.count == 2 && curve[0].x == 0 && curve[0].y == 0 && curve[1].x == 1 && curve[1].y == 1 }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func d(_ k: CodingKeys, _ v: Double = 0) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? v }
        exposure = try d(.exposure); contrast = try d(.contrast); highlights = try d(.highlights); shadows = try d(.shadows)
        clarity = try d(.clarity); dehaze = try d(.dehaze); temperature = try d(.temperature); tint = try d(.tint)
        saturation = try d(.saturation); colorHue = try d(.colorHue, 40); colorAmount = try d(.colorAmount); grain = try d(.grain)
        curve = try c.decodeIfPresent([CurvePoint].self, forKey: .curve) ?? [CurvePoint(0, 0), CurvePoint(1, 1)]
    }
}

/// A mask and its adjustments ("local adjustment").
public struct LocalAdjustment: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var enabled = true
    public var invert = false
    public var components: [MaskComponent]
    public var settings = LocalSettings()

    public init(name: String, components: [MaskComponent]) { self.name = name; self.components = components }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        components = try c.decodeIfPresent([MaskComponent].self, forKey: .components) ?? []
        settings = try c.decodeIfPresent(LocalSettings.self, forKey: .settings) ?? LocalSettings()
    }

    /// The most masks the engine applies at once, and parts across all of them.
    public static let maximumCount = 8
    public static let maximumComponents = 32
}
