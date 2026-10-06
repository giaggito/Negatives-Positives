import Foundation

/// Another photograph laid over the edited one — a double exposure.
///
/// The layer is placed on the base photo's sensor (like two exposures on one negative): cropping, turning or
/// straightening the photo afterwards moves both together. Position and size are in sensor coordinates
/// divided by the sensor's long side (as masks are); `angle` is measured in the sensor's frame.
public struct PhotoLayer: Codable, Equatable, Identifiable, Sendable {
    /// How the layer's light combines with the photo's.
    public enum Blend: String, Codable, CaseIterable, Sendable {
        /// Two exposures on one frame: the light adds up, each exposure given half (as a photographer stops
        /// down one stop for each of two exposures). Bright parts of either picture show; dark parts let the
        /// other through.
        case film
        /// Like film, but bright areas never burn out (the classic digital double exposure).
        case screen
        /// Keeps whichever is brighter.
        case lighten
        /// Keeps whichever is darker.
        case darken
        /// Darkens with the layer, as if the photo were printed through it.
        case multiply
        /// The layer covers the photo (lower Amount to see through it).
        case normal

        public var title: String {
            switch self {
            case .film: return "Film"
            case .screen: return "Screen"
            case .lighten: return "Lighten"
            case .darken: return "Darken"
            case .multiply: return "Multiply"
            case .normal: return "Normal"
            }
        }

        public var explanation: String {
            switch self {
            case .film: return "Like two exposures on one frame of film: the light of both adds up, each at half. Bright parts of either photo show; dark parts let the other through."
            case .screen: return "Like Film, but highlights never burn out — the classic digital double exposure."
            case .lighten: return "Keeps whichever photo is brighter at each point."
            case .darken: return "Keeps whichever photo is darker at each point."
            case .multiply: return "Darkens the photo with the layer, as if printed through it."
            case .normal: return "The layer covers the photo; lower Amount to see through it."
            }
        }

        /// Code used by the `layer_composite` kernel.
        public var code: Int { Self.allCases.firstIndex(of: self)! }
    }

    public var id = UUID()
    /// The layer's file.
    public var path: String
    public var enabled = true
    public var blend: Blend = .film
    /// 0…100: how much of the layer is laid in.
    public var amount: Double = 100
    /// Stops added to the layer's own default brightness.
    public var exposure: Double = 0
    /// −100 (cooler) … 100 (warmer), −100 (green) … 100 (magenta), around the layer's own white balance.
    public var temperature: Double = 0
    public var tint: Double = 0
    /// Where the layer's centre lies on the photo's sensor (fraction of the long side).
    public var center = MaskPoint(0.5, 0.33)
    /// The layer's long side as a fraction of the photo sensor's long side.
    public var size = 1.0
    /// Rotation in degrees (counter-clockwise on the sensor), and mirroring of the layer.
    public var angle = 0.0
    public var flip = false
    /// Where the layer shows: everywhere when the mask has no parts.
    public var mask = LocalAdjustment(name: "Where it shows", components: [])

    public init(path: String) { self.path = path }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
    public var isMasked: Bool { !mask.components.isEmpty }

    public static let maximumCount = 3

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        blend = (try? c.decodeIfPresent(Blend.self, forKey: .blend)) ?? .film
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 100
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        center = try c.decodeIfPresent(MaskPoint.self, forKey: .center) ?? MaskPoint(0.5, 0.33)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 0
        flip = try c.decodeIfPresent(Bool.self, forKey: .flip) ?? false
        mask = try c.decodeIfPresent(LocalAdjustment.self, forKey: .mask) ?? LocalAdjustment(name: "Where it shows", components: [])
    }
}
