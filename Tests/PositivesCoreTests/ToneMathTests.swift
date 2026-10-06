import Foundation
import simd
import Testing
@testable import PositivesCore

@Suite("Colour and tone maths")
struct ToneMathTests {
    @Test func shoulderIsExactlyInvertibleAndIdentityBelowKnee() {
        for i in 0...1000 {
            let y = Float(i) / 1000
            let x = ToneMath.shoulderInverse(y)
            #expect(abs(ToneMath.shoulder(x) - y) <= 2e-7, "y = \(y)")
            if y <= ToneMath.knee { #expect(x == y) }
        }
        #expect(ToneMath.shoulderInverse(1).isFinite)
    }

    @Test func shoulderIsMonotonicAndBounded() {
        var prev: Float = -1
        for i in 0...4000 {
            let v = ToneMath.shoulder(Float(i) / 200)
            #expect(v >= prev)
            #expect(v <= 1)
            prev = v
        }
    }

    @Test func oklabRoundTrip() {
        for r in stride(from: Float(0), through: 1.5, by: 0.25) {
            for g in stride(from: Float(0), through: 1.5, by: 0.25) {
                for b in stride(from: Float(0), through: 1.5, by: 0.25) {
                    let c = SIMD3(r, g, b)
                    #expect(simd_length(ToneMath.fromOklab(ToneMath.oklab(c)) - c) < 2e-5)
                }
            }
        }
        // D65 white is neutral in OKLab.
        let w = ToneMath.oklab(SIMD3(1, 1, 1))
        #expect(abs(w.y) < 1e-6 && abs(w.z) < 1e-6)
        #expect(abs(w.x - 1) < 1e-3)
    }

    @Test func contrastCurveIsMonotonicAndFixesPivotAndEnds() {
        for c in stride(from: -1.0, through: 1.0, by: 0.25) {
            let k = Float(pow(2, 0.9 * c))
            #expect(ToneMath.contrast(0, k: k) == 0)
            #expect(abs(ToneMath.contrast(1, k: k) - 1) < 1e-6)
            #expect(abs(ToneMath.contrast(ToneMath.pivot, k: k) - ToneMath.pivot) < 1e-6)
            var prev: Float = -1
            for i in 0...1000 {
                let v = ToneMath.contrast(Float(i) / 1000, k: k)
                #expect(v >= prev)
                prev = v
            }
        }
    }

    @Test func whitesAndBlacksAreMonotonic() {
        for w in [-1, -0.5, 0, 0.5, 1] as [Float] {
            for b in [-1, -0.5, 0, 0.5, 1] as [Float] {
                var prev: Float = -10
                for i in 0...1000 {
                    let v = ToneMath.whitesBlacks(Float(i) / 1000, whites: w, blacks: b)
                    #expect(v > prev)
                    prev = v
                }
            }
        }
    }

    @Test func printCurveKeepsMiddleGreyAndNeutrals() {
        let r = ToneMath.printCurve(for: .standard)!.resolved
        #expect(abs(ToneMath.printCurve(0.18, r) - 0.18) < 1e-4)
        let p = DevelopParameters(inputMatrix: matrix_identity_float3x3, unrender: false, exposureGain: 1, exposureStops: 0,
                                  profileKind: 1, print: r)
        for v in [0.001, 0.05, 0.18, 0.9, 4] as [Float] {
            let o = Develop.pixel(SIMD3(repeating: v), p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0))
            #expect(abs(o.x - o.y) < 1e-4 * max(1, o.y) && abs(o.z - o.y) < 1e-4 * max(1, o.y), "grey \(v) -> \(o)")
        }
    }

    @Test func toneCurveKeepsHue() {
        let r = ToneMath.printCurve(for: .standard)!.resolved
        let p = DevelopParameters(inputMatrix: matrix_identity_float3x3, unrender: false, exposureGain: 2, exposureStops: 1,
                                  profileKind: 1, print: r)
        for c in [SIMD3<Float>(0.8, 0.2, 0.05), SIMD3(0.05, 0.4, 0.9), SIMD3(0.3, 0.6, 0.1)] {
            let o = Develop.pixel(c, p, local: LocalValues(base: 0, mid: 0, fine: 0, dark: 0))
            let a = ToneMath.oklab(c), b = ToneMath.oklab(o)
            let ha = atan2(a.z, a.y), hb = atan2(b.z, b.y)
            #expect(abs(ha - hb) < 2e-3, "hue moved for \(c)")
        }
    }

    @Test func rawWhiteBalanceReproducesTheCamerasAsShotNeutral() {
        let s = TestFiles.syntheticRaw()
        // A neutral under the shooting light, in balanced camera RGB:
        let xyz = ColorScience.xyz(fromXY: ColorScience.xy(fromUV: s.asShotWhiteBalance.sourceWhiteUV))
        let cam = s.cameraToRec2020.inverse * (ColorScience.rec2020.fromXYZ * xyz)
        let out = s.inputMatrix(whiteBalance: nil) * cam
        #expect(abs(out.x - 1) < 1e-9 && abs(out.y - 1) < 1e-9 && abs(out.z - 1) < 1e-9, "\(out)")
        // and the eyedropper on that colour gives back the as-shot setting
        let wb = s.whiteBalance(neutralizing: cam)!
        #expect(abs(wb.temperature - s.asShotWhiteBalance.temperature) < 0.5)
        #expect(abs(wb.tint - s.asShotWhiteBalance.tint) < 0.05)
    }

    @Test func eightBitDitherIsExactOnCodesAndUnbiasedBetweenThem() {
        // Exact codes stay exact.
        for k in 0...255 {
            #expect(Exporter.quantize8(Double(k) / 255, x: k, y: 3, channel: 1) == UInt8(k))
        }
        // A value a quarter of the way between two codes rounds up 25 % of the time.
        var ups = 0
        let n = 40000
        for i in 0..<n where Exporter.quantize8((100.25) / 255, x: i % 200, y: i / 200, channel: 0) == 101 { ups += 1 }
        #expect(abs(Double(ups) / Double(n) - 0.25) < 0.01)
    }
}
