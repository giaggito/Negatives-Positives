import CoreGraphics
import Foundation
import simd
import Testing
@testable import NegativesCore

@Suite("Print curve")
struct PrintCurveTests {
    let curves = [PrintCurve(), PrintCurve(exposure: 1.3, contrast: 0.8, toe: 0, shoulder: 1, paperDmax: 2.0),
                  PrintCurve(exposure: -2, contrast: 2.2, toe: 1, shoulder: 0, paperDmax: 3.0)]

    @Test func middleGreyIsPivot() {
        for var c in curves {
            c.exposure = 0
            #expect(abs(c.apply(0.18) - 0.18) < 1e-12)
        }
    }

    @Test func monotonicBoundedAndInvertible() {
        for c in curves {
            let r = c.resolved
            var prev = 0.0
            for i in 0..<2000 {
                let l = pow(10, -6 + 9 * Double(i) / 1999)
                let y = c.apply(l)
                #expect(y > prev)
                #expect(y > pow(10, -c.paperDmax) * 0.999 && y < 1)
                prev = y
                if y > pow(10, -c.paperDmax) * 1.01 && y < 0.99 {
                    #expect(abs(PrintCurve.invert(y, r) / l - 1) < 1e-6)
                }
            }
        }
    }

    @Test func slopeAtPivotEqualsContrast() {
        for c in curves {
            let h = 1e-5
            let pivot = 0.18 * pow(2, -c.exposure)
            let d = (log10(c.apply(pivot * pow(10, h))) - log10(c.apply(pivot * pow(10, -h)))) / (2 * h)
            #expect(abs(d - c.contrast) < 1e-3)
        }
    }
}

@Suite("White balance")
struct WhiteBalanceTests {
    @Test func referenceIsIdentity() {
        let m = WhiteBalance.neutral.matrix
        #expect(simd_almost_equal_elements(m, matrix_identity_double3x3, 1e-12))
        // Also through the general path
        let m2 = WhiteBalance(temperature: 6504, tint: 1e-12).matrix
        #expect(simd_almost_equal_elements(m2, matrix_identity_double3x3, 1e-6))
    }

    @Test func warmerAndMagentaLikeAPhotoEditor() {
        let grey = SIMD3<Double>(repeating: 0.18)
        let warm = WhiteBalance(temperature: 8000, tint: 0).matrix * grey
        #expect(warm.x > warm.z)
        let cool = WhiteBalance(temperature: 4500, tint: 0).matrix * grey
        #expect(cool.z > cool.x)
        let magenta = WhiteBalance(temperature: 6504, tint: 40).matrix * grey
        #expect(magenta.y < magenta.x && magenta.y < magenta.z)
    }

    @Test func whiteBalanceKeepsLuminanceOfNeutralsClose() {
        let y = ColorScience.rec2020.toXYZ * (WhiteBalance(temperature: 5000, tint: 10).matrix * SIMD3(repeating: 0.5))
        #expect(abs(y.y - 0.5) < 0.03)
    }

    @Test func eyedropperNeutralisesPickedColour() {
        let picks: [SIMD3<Double>] = [[0.30, 0.22, 0.15], [0.12, 0.15, 0.22], [0.2, 0.25, 0.2], [0.25, 0.18, 0.24], [0.4, 0.4, 0.4]]
        for p in picks {
            let wb = try! #require(WhiteBalance.neutralizing(p))
            let out = wb.matrix * p
            let xy = ColorScience.xy(fromXYZ: ColorScience.rec2020.toXYZ * out)
            #expect(simd_distance(xy, ColorScience.d65) < 1e-6, "pick \(p) -> \(wb)")
        }
    }
}

@Suite("Film calibration")
struct CalibrationTests {
    /// The heart of the "no different casts in shadows and highlights" requirement: with per-layer gammas,
    /// a neutral grey scale becomes exactly neutral at every density after the two-point calibration.
    @Test func neutralAtEveryLevel() {
        let film = SyntheticFilm()
        let base = film.rebate
        let lo = NegativeModel.density(film.scan(exposure: SIMD3(repeating: 0.02)), base: base)
        let hi = NegativeModel.density(film.scan(exposure: SIMD3(repeating: 0.9)), base: base)
        let cal = FilmCalibration.from(shadow: lo, highlight: hi)
        for i in 0...50 {
            let g = pow(10, log10(0.005) + Double(i) / 50 * (log10(3.0) - log10(0.005)))
            let e = cal.equivalentDensity(NegativeModel.density(film.scan(exposure: SIMD3(repeating: g)), base: base))
            #expect(abs(e.x - e.y) < 1e-12 && abs(e.z - e.y) < 1e-12, "grey \(g): \(e)")
        }
        #expect(abs(cal.gammaRatio.x - film.gamma.x / film.gamma.y) < 1e-12)
        #expect(abs(cal.gammaRatio.z - film.gamma.z / film.gamma.y) < 1e-12)
    }

    @Test func naiveInversionHasCastsThatDependOnTone() {
        // What a single "white balance" (offset-only) correction would leave behind, for contrast.
        let film = SyntheticFilm()
        let base = film.rebate
        let mid = NegativeModel.density(film.scan(exposure: SIMD3(repeating: 0.18)), base: base)
        let cal = FilmCalibration(gammaRatio: [1, 1, 1], offset: mid - SIMD3(repeating: mid.y))
        let dark = cal.equivalentDensity(NegativeModel.density(film.scan(exposure: SIMD3(repeating: 0.02)), base: base))
        #expect(abs(dark.x - dark.z) > 0.1)
    }
}

@Suite("Colour science")
struct ColorScienceTests {
    @Test func rgbToXYZWhitePoints() {
        for s in [ColorScience.sRGB, ColorScience.rec2020, ColorScience.displayP3, ColorScience.adobeRGB, ColorScience.proPhoto] {
            let w = s.toXYZ * SIMD3(1, 1, 1)
            #expect(simd_distance(ColorScience.xy(fromXYZ: w), s.white) < 1e-12)
            #expect(abs(w.y - 1) < 1e-12)
        }
    }

    @Test func knownSRGBMatrix() {
        let m = ColorScience.sRGB.toXYZ
        #expect(abs(m[0][0] - 0.4124) < 1e-3 && abs(m[1][1] - 0.7152) < 1e-3 && abs(m[2][2] - 0.9505) < 1e-3)
    }

    @Test func cameraMatrixKeepsNeutrals() {
        let m = ColorScience.sRGBToRec2020 * xe4CameraToSRGB
        let v = m * SIMD3(0.3, 0.3, 0.3)
        #expect(abs(v.x - 0.3) < 1e-3 && abs(v.y - 0.3) < 1e-3 && abs(v.z - 0.3) < 1e-3)
    }
}

@Suite("Geometry")
struct GeometryTests {
    @Test func quarterTurnsMapCorners() {
        let W = 60, H = 40
        var g = FrameGeometry()
        g.quarterTurns = 1  // clockwise: the source's top-left lands at the output's top-right
        let a = g.outputToSource(sourceWidth: W, sourceHeight: H)
        let outSize = g.outputSize(sourceWidth: W, sourceHeight: H)
        #expect(outSize.width == H && outSize.height == W)
        let p = a.apply([Double(outSize.width) - 0.5, 0.5])
        #expect(simd_distance(p, [0.5, 0.5]) < 1e-12)
        g.quarterTurns = 3
        let b = g.outputToSource(sourceWidth: W, sourceHeight: H)
        #expect(simd_distance(b.apply([0.5, Double(W) - 0.5]), [0.5, 0.5]) < 1e-12)
    }

    @Test func flipsAndCrop() {
        var g = FrameGeometry(flipHorizontal: true)
        g.crop = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.5)
        let a = g.outputToSource(sourceWidth: 100, sourceHeight: 80)
        // Output (0.5,0.5) -> canvas (25.5, 40.5) -> unflipped x = 100 − 25.5
        #expect(simd_distance(a.apply([0.5, 0.5]), [74.5, 40.5]) < 1e-12)
        #expect(g.isPixelExact(sourceWidth: 100, sourceHeight: 80))
    }
}
