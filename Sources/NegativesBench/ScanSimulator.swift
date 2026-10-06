import CoreGraphics
import Foundation
import NegativesCore
import PositivesCore
import simd

/// A physically simulated scan of a colour negative: the scene exposes a real stock (spectral sensitivities,
/// characteristic curves, couplers — `PreparedFilm`), the developed dyes and the orange base filter a light
/// source, and a camera with given spectral sensitivities records the result as a RAW file would (balanced
/// for daylight, linear, with its own camera → sRGB matrix).
public struct Camera {
    public let name: String
    /// Spectral sensitivities on `Spectral.wavelengths` (R, G, B).
    public let ssf: [SIMD3<Double>]

    public static func gauss(_ c: Double, _ s: Double) -> [Double] { Spectral.wavelengths.map { exp(-0.5 * pow(($0 - c) / s, 2)) } }

    static func make(_ name: String, _ r: [Double], _ g: [Double], _ b: [Double]) -> Camera {
        Camera(name: name, ssf: (0..<Spectral.count).map { SIMD3(r[$0], g[$0], b[$0]) })
    }

    /// Typical CMOS (crosstalk lobes), a wider / shifted one, and a narrow-band one.
    public static let all: [Camera] = [
        make("cmos", zip(gauss(600, 30), gauss(450, 25)).map { $0 + 0.1 * $1 },
             zip(gauss(535, 38), gauss(620, 30)).map { $0 + 0.05 * $1 },
             zip(gauss(458, 28), gauss(530, 30)).map { $0 + 0.05 * $1 }),
        make("wide", gauss(590, 42), gauss(525, 46), gauss(462, 36)),
        make("narrow", gauss(620, 22), gauss(540, 25), gauss(450, 20)),
    ]

    /// Camera RGB of a spectrum (radiance per wavelength).
    public func response(_ spd: [Double]) -> SIMD3<Double> {
        var acc = SIMD3<Double>.zero
        for i in 0..<Spectral.count { acc += spd[i] * ssf[i] }
        return acc
    }

    /// Daylight balance (D65 → equal channels) and the balanced-camera → linear sRGB matrix, fitted on natural
    /// reflectances under D65 with rows summing to 1 — what LibRaw provides for a real camera.
    public func calibration() -> (mul: SIMD3<Double>, toSRGB: simd_double3x3) {
        let d65 = Spectral.illuminant("D65")
        let white = response(d65)
        let mul = SIMD3<Double>(repeating: white.y) / white
        let toXYZ = Spectral.toRec2020(adaptingFrom: Spectral.xyz(d65))
        let r2020ToSRGB = ColorScience.sRGBToRec2020.inverse
        var ata = simd_double3x3(), atb = simd_double3x3()
        let n = SpectralUpsampling.gridSize
        for j in stride(from: 0, to: n, by: 2) {
            for i in stride(from: 0, to: n, by: 2) {
                guard let coef = SpectralUpsampling.coefficients[i * n + j] ?? nil else { continue }
                let r = SpectralUpsampling.reflectance(coef)
                let spd = (0..<Spectral.count).map { d65[$0] * r[$0] }
                let cam = response(spd) * mul / white.y
                let srgb = r2020ToSRGB * (toXYZ * Spectral.xyz(spd))
                ata += simd_double3x3(columns: (cam * cam.x, cam * cam.y, cam * cam.z))
                atb += simd_double3x3(columns: (srgb * cam.x, srgb * cam.y, srgb * cam.z))
            }
        }
        var m = atb * ata.inverse
        // Rows sum to 1 (neutral stays neutral).
        let rows = m.transpose
        var fixed: [SIMD3<Double>] = []
        for k in 0..<3 { let row = rows[k]; fixed.append(row / (row.x + row.y + row.z)) }
        m = simd_double3x3(rows: fixed)
        return (mul, m)
    }
}

public struct Light {
    public let name: String
    public let spd: [Double]
    public static let all: [Light] = [
        Light(name: "daylight", spd: Spectral.daylight(5000)),
        Light(name: "tungsten", spd: Spectral.blackbody(3000)),
        // White LED: blue pump + broad phosphor.
        Light(name: "led", spd: zip(Camera.gauss(450, 10), Camera.gauss(570, 60)).map { 0.55 * $0 + $1 }),
    ]
}

/// The stock and its scan.
public final class ScanSimulator {
    public let film: PreparedFilm
    public let camera: Camera
    public let light: Light
    public let mul: SIMD3<Double>
    public let toSRGB: simd_double3x3
    /// Camera RGB through bare light (no film) and through the film base, unscaled.
    public let open: SIMD3<Double>
    public let baseValue: SIMD3<Double>
    private let lightCam: [SIMD3<Double>]       // light × ssf per wavelength

    public init?(stock: String, camera: Camera, light: Light) {
        var fs = FilmSettings()
        fs.stock = stock
        guard let f = PreparedFilm.prepare(fs) else { return nil }
        film = f
        self.camera = camera
        self.light = light
        (mul, toSRGB) = camera.calibration()
        lightCam = (0..<Spectral.count).map { light.spd[$0] * camera.ssf[$0] }
        var o = SIMD3<Double>.zero, b = SIMD3<Double>.zero
        for i in 0..<Spectral.count {
            o += lightCam[i]
            b += lightCam[i] * pow(10, -Double(f.filmDyeBase[i].w))
        }
        open = o * mul
        baseValue = b * mul
    }

    /// Balanced camera RGB behind the film for a scene colour (linear Rec.2020, middle grey 0.184) exposed with
    /// `ev` stops of over / under exposure. Unscaled: divide by `open.max()` for the sensor value of the panel.
    public func cameraValue(scene rgb: SIMD3<Float>, ev: Float) -> SIMD3<Double> {
        let d = film.develop(film.exposure(rgb) * film.gain * pow(2, ev))
        var acc = SIMD3<Double>.zero
        for i in 0..<Spectral.count {
            let dy = film.filmDyeBase[i]
            let od = Double(d.x * dy.x + d.y * dy.y + d.z * dy.z + dy.w)
            acc += lightCam[i] * pow(10, -od)
        }
        return acc * mul
    }
}

public enum Framing: String, CaseIterable {
    /// The picture fills the scan.
    case tight
    /// A film strip on a light table: rebate with sprocket holes above and below, panel at the sides.
    case strip
    /// An opaque holder around the picture.
    case holder
    /// Holder around a strip: rebate and holes inside a black frame.
    case stripHolder
}

extension ScanSimulator {
    /// A whole scan as a RAW file would give it: balanced camera RGB, 1.0 = sensor clip, 14-bit, with noise.
    /// The panel reaches `brightness` of the clip level. Returns the scan and the picture rectangle (pixels).
    public func scan(scene: LinearImage, ev: Float, framing: Framing, brightness: Double = 0.85, seed: UInt64 = 1) -> (RawImage, CGRect) {
        let pw = scene.width, ph = scene.height
        let (mx, my): (Int, Int)
        switch framing {
        case .tight: (mx, my) = (0, 0)
        case .strip, .stripHolder: (mx, my) = (pw / 14, ph / 5)
        case .holder: (mx, my) = (pw / 16, ph / 16)
        }
        let w = pw + 2 * mx, h = ph + 2 * my
        let k = brightness / open.max()
        let panel = open * k, base = baseValue * k
        let flare = open * k * 0.004
        var px = [Float](repeating: 1, count: w * h * 4)
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u1 = Double((state >> 11) & 0xFFFFF) / Double(0x100000) + 1e-9
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u2 = Double((state >> 11) & 0xFFFFF) / Double(0x100000)
            return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
        }
        // Picture.
        var picture = [SIMD3<Double>](repeating: .zero, count: pw * ph)
        DispatchQueue.concurrentPerform(iterations: ph) { y in
            for x in 0..<pw { picture[y * pw + x] = cameraValue(scene: scene[x, y], ev: ev) * k }
        }
        let holeW = max(4, pw / 40), holeH = max(4, my / 3), pitch = max(holeW * 2, pw / 16)
        for y in 0..<h {
            for x in 0..<w {
                var v: SIMD3<Double>
                let inPic = x >= mx && x < mx + pw && y >= my && y < my + ph
                if inPic {
                    v = picture[(y - my) * pw + (x - mx)]
                } else {
                    switch framing {
                    case .tight: v = panel
                    case .holder: v = flare
                    case .strip, .stripHolder:
                        let inStripX = framing == .strip || (x >= mx / 2 && x < w - mx / 2)
                        let inStripY = y >= my / 4 && y < h - my / 4
                        if !(inStripX && inStripY) {
                            v = framing == .strip ? panel : flare
                        } else {
                            // Rebate band with sprocket holes.
                            let band = y < my ? y - my / 4 : y - (my + ph)
                            let hole = band >= (my * 3 / 4 - holeH) / 2 && band < (my * 3 / 4 + holeH) / 2 && (x % pitch) < holeW
                            v = hole ? panel : base
                        }
                    }
                }
                let i = (y * w + x) * 4
                for c in 0..<3 {
                    let s = max(0, v[c] + noise() * sqrt(v[c] * 2e-5 + 4e-8))
                    px[i + c] = Float((min(s, 1) * 16383).rounded() / 16383)
                }
            }
        }
        let img = LinearImage(width: w, height: h, pixels: px)
        let raw = RawImage(image: img, cameraMake: "Bench", cameraModel: camera.name, multipliers: [1, 1, 1], clipLevel: [1, 1, 1],
                           cameraToSRGB: toSRGB, isoSpeed: 100, shutter: 0.01)
        return (raw, CGRect(x: mx, y: my, width: pw, height: ph))
    }
}
