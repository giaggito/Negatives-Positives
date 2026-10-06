import CoreGraphics
import Foundation
import simd

/// Settings shared by every frame of a roll (stored in `Roll.negatives.json` in the roll folder).
/// Holds both user inputs and the measurements derived from them, so a roll always re-renders identically.
public struct RollSettings: Codable, Equatable, Sendable {
    /// 2: calibration and exposure from `FrameStats` (picture detection, neutral fit, large-area exposure).
    public static let currentVersion = 2
    public var version = RollSettings.currentVersion
    /// Colour negative or black & white film.
    public var monochrome = false
    /// Average film gamma used to turn density into scene exposure. C-41 ≈ 0.6, typical B&W ≈ 0.65.
    public var filmGamma = 0.6

    /// Where the user measured the film base: file name and a normalised rectangle in sensor coordinates.
    public var filmBaseSource: FilmBaseSource?
    /// Measured film base in camera RGB (after flat-field). `nil` until measured.
    public var filmBase: SIMD3<Double>?
    public var filmBaseClipped: Double?

    /// Bare light-panel shot (file name relative to the roll folder) used for flat-field correction.
    public var flatFieldFile: String?

    /// Pooled neutral-lock calibration and highlight reference. `nil` until the roll is analysed.
    public var calibration: FilmCalibration?
    public var referenceDensity: Double?

    public init() {}

    public struct FilmBaseSource: Codable, Equatable, Sendable {
        public var file: String
        /// Normalised (0…1) rectangle in sensor coordinates; `nil` means automatic estimate.
        public var rect: CGRect?
        public init(file: String, rect: CGRect?) { self.file = file; self.rect = rect }
    }
}

/// Per-frame settings, layered over the roll (stored next to each RAF as `<name>.negatives.json`).
public struct FrameSettings: Codable, Equatable, Sendable {
    public var version = 1
    public var geometry = FrameGeometry()

    /// User exposure offset in stops, added to the automatic per-frame exposure.
    public var exposure = 0.0
    public var autoExposureEnabled = true
    public var curve = PrintCurve()
    public var whiteBalance = WhiteBalance.neutral
    /// Overrides the roll's colour/B&W mode for this frame.
    public var monochrome: Bool?
    public var monochromeWeights = SIMD3<Double>(0.25, 0.5, 0.25)

    /// Measured on this frame's picture (inside its crop). Feeds the roll calibration and the auto exposure.
    public var stats: FrameStats?
    /// Optional per-frame replacement for the roll calibration (advanced).
    public var calibrationOverride: FilmCalibration?

    public init() {}

    /// The settings a user expects to copy from one frame to another (look, not framing or measurements).
    public func pastingLook(onto other: FrameSettings) -> FrameSettings {
        var s = other
        s.exposure = exposure
        s.autoExposureEnabled = autoExposureEnabled
        s.curve = curve
        s.whiteBalance = whiteBalance
        s.monochrome = monochrome
        s.monochromeWeights = monochromeWeights
        s.calibrationOverride = calibrationOverride
        return s
    }
}

public enum SettingsError: Error, CustomStringConvertible {
    case notMeasured(String)
    public var description: String {
        switch self { case .notMeasured(let s): return s }
    }
}

extension ConversionParameters {
    /// Resolves layered settings into the numbers the pipeline runs on.
    public static func resolve(roll: RollSettings, frame: FrameSettings, cameraToRec2020: simd_double3x3) throws -> ConversionParameters {
        guard let base = roll.filmBase else { throw SettingsError.notMeasured("Film base has not been measured") }
        let mono = frame.monochrome ?? roll.monochrome
        let w = frame.monochromeWeights
        let calibration = frame.calibrationOverride ?? roll.calibration
            ?? frame.stats.map { mono ? .identity : Estimators.rollCalibration(stats: [$0]) }
            ?? .identity
        let monoWeights: SIMD3<Double>? = mono ? w / max(w.x + w.y + w.z, 1e-9) : nil
        let reference = roll.referenceDensity
            ?? frame.stats.map { Estimators.frameReference($0, calibration, filmGamma: roll.filmGamma, monochromeWeights: monoWeights) }
            ?? 1.0
        let auto = (frame.autoExposureEnabled ? frame.stats.map {
            Estimators.autoExposure(stats: $0, calibration: calibration, referenceDensity: reference, filmGamma: roll.filmGamma,
                                    monochromeWeights: monoWeights)
        } : nil) ?? 0
        var curve = frame.curve
        curve.exposure = auto + frame.exposure
        return ConversionParameters(
            filmBase: base,
            calibration: calibration,
            referenceDensity: reference,
            filmGamma: roll.filmGamma,
            monochrome: mono,
            monochromeWeights: w / max(w.x + w.y + w.z, 1e-9),
            colorMatrix: frame.whiteBalance.matrix * cameraToRec2020,
            curve: curve.resolved
        )
    }
}

/// JSON sidecar storage.
public enum Sidecar {
    public static let rollFileName = "Roll.negatives.json"

    public static func frameURL(for raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension("negatives.json")
    }

    public static func rollURL(in folder: URL) -> URL { folder.appendingPathComponent(rollFileName) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    public static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
