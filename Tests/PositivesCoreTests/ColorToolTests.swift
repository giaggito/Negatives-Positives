import Foundation
import simd
import Testing
@testable import PositivesCore

@Suite("Curves and colour tools")
struct ColorToolTests {
    @Test func curveGoesThroughPointsAndNeverOvershoots() {
        let pts = [CurvePoint(0, 0), CurvePoint(0.25, 0.1), CurvePoint(0.5, 0.6), CurvePoint(0.75, 0.62), CurvePoint(1, 1)]
        for p in pts { #expect(abs(CurveMath.evaluate(pts, p.x) - p.y) < 1e-12) }
        // Monotone data -> monotone curve, and every value stays within its segment's endpoints.
        var prev = -1.0
        for i in 0...1000 {
            let x = Double(i) / 1000
            let y = CurveMath.evaluate(pts, x)
            #expect(y >= prev - 1e-12)
            prev = y
            if let k = pts.indices.dropLast().first(where: { pts[$0].x <= x && x <= pts[$0 + 1].x }) {
                #expect(y >= min(pts[k].y, pts[k + 1].y) - 1e-9 && y <= max(pts[k].y, pts[k + 1].y) + 1e-9)
            }
        }
    }

    @Test func identityCurveIsExactlyIdentityAndExtendsBeyondWhite() {
        let lut = CurveMath.bake(ToneCurves())
        for i in 0...200 {
            let x = Float(i) / 200
            #expect(abs(CurveMath.lookup(lut, x, channel: 0) - x) < 1e-6)
        }
        #expect(abs(CurveMath.lookup(lut, 1.5, channel: 2) - 1.5) < 1e-6)
        #expect(ToneCurves().isNeutral)
    }

    @Test func mixerWeightsArePartitionOfUnityAndHitCentres() {
        for (k, c) in ColorMath.mixerCentres.enumerated() {
            let (i, j, w) = ColorMath.mixerWeights(hue: c + 1e-5)
            #expect((i == k && w > 0.999) || (j == k && w < 0.001))
        }
        // Neutral pixels are untouched by any mixer setting.
        let grey = SIMD3<Float>(0.6, 0, 0)
        let r = (0..<8).map { _ in SIMD3<Float>(0.5, 0.8, -0.7) }
        #expect(ColorMath.applyMixer(grey, r) == grey)
    }

    @Test func targetedColourSelectsItsHueOnly() {
        var t = TargetedColor(hue: 40, chroma: 0.12, lightness: 0.6)
        t.width = 20; t.softness = 30
        let p = ColorMath.Target(t)
        func lab(_ hueDeg: Float, _ c: Float) -> SIMD3<Float> { SIMD3(0.6, c * cos(hueDeg * .pi / 180), c * sin(hueDeg * .pi / 180)) }
        #expect(ColorMath.targetWeight(lab(40, 0.12), p) > 0.99)
        #expect(ColorMath.targetWeight(lab(120, 0.12), p) == 0)
        #expect(ColorMath.targetWeight(lab(40, 0.005), p) == 0)        // greys are not selected
    }

    @Test func neutralGradingChangesNothing() {
        #expect(ColorGrading().isNeutral)
        let g = ColorMath.Grading(ColorGrading())
        let lab = SIMD3<Float>(0.5, 0.03, -0.02)
        #expect(ColorMath.applyGrading(lab, g) == lab)
    }

    @Test func editsWithMissingFieldsStillLoad() throws {
        let json = #"{"formatVersion":1,"light":{"exposure":0.5,"contrast":10,"highlights":0,"shadows":0,"whites":0,"blacks":0},"presence":{"clarity":20,"texture":0,"dehaze":0,"vibrance":30,"saturation":-10},"enabled":{"whiteBalance":true,"light":true,"presence":true},"cropAspect":"original","geometry":{"quarterTurns":1,"flipHorizontal":false,"flipVertical":false,"straighten":0,"crop":[[0,0],[1,1]]}}"#
        let e = try JSONDecoder().decode(EditState.self, from: Data(json.utf8))
        #expect(e.light.exposure == 0.5 && e.presence.clarity == 20)
        #expect(e.geometry.quarterTurns == 1 && e.curves.isNeutral && e.enabled.curves)
    }
}
