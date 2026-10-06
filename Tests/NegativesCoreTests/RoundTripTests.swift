import CoreGraphics
import Foundation
import simd
import Testing
@testable import NegativesCore

/// Positive -> synthetic negative -> Negatives -> positive, measured with CIEDE2000.
///
/// The comparison is made on the scene-linear output (before the print curve, which is a deliberate
/// rendering choice rather than part of the inversion). One global exposure scale is matched on the
/// middle-grey patch, because absolute exposure is unknowable from a negative.
@Suite("Round trip (synthetic film)")
struct RoundTripTests {

    struct Result: CustomStringConvertible {
        var mean: Double, max: Double, worst: String, perPatch: [(String, Double)]
        var description: String {
            String(format: "mean ΔE00 %.3f  max %.3f (%@)", mean, max, worst)
        }
    }

    /// Runs the CPU reference conversion on the synthetic scan and measures ΔE00 against the original chart.
    static func run(film: SyntheticFilm, filmGamma: Double? = nil, calibration: (SyntheticScan, SIMD3<Double>) -> FilmCalibration,
                    gpu: Bool = false) throws -> Result {
        let scan = SyntheticScan(film: film)
        let proxy = AnalysisProxy(image: scan.image, sourceWidth: scan.image.width, sourceHeight: scan.image.height,
                                  clipLevel: [1, 1, 1], flat: nil)
        var roll = RollSettings()
        roll.filmGamma = filmGamma ?? film.gamma.y
        #expect(Processor.measureFilmBase(proxy, file: "synthetic", rect: scan.rebateRect, roll: &roll))
        let base = try #require(roll.filmBase)
        #expect(simd_distance(base, film.rebate) < 1e-6)

        var frame = FrameSettings()
        frame.monochrome = false
        // Crop away the rebate strip, like a user would.
        let rebateFraction = scan.rebateRect.height
        frame.geometry.crop = CGRect(x: 0, y: rebateFraction, width: 1, height: 1 - rebateFraction)
        Processor.measureAnchors(proxy, roll: roll, settings: &frame)
        roll.calibration = calibration(scan, base)
        frame.autoExposureEnabled = false
        if let st = frame.stats { roll.referenceDensity = Estimators.frameReference(st, roll.calibration!, filmGamma: roll.filmGamma) }

        let camToRec = ColorScience.sRGBToRec2020 * xe4CameraToSRGB
        var p = try ConversionParameters.resolve(roll: roll, frame: frame, cameraToRec2020: camToRec)
        // This idealised film's layers are exactly the camera's channels: the colour model (made for real
        // cameras' overlapping filters, tested with the spectral bench) does not apply.
        p.colourModel = matrix_identity_double3x3

        var recovered: [SIMD3<Double>]
        if gpu {
            let g = try #require(GPUPipeline.shared)
            let out = g.download(try g.convert(try g.upload(scan.image), parameters: p, stage: .sceneLinear))
            recovered = scan.patchCentres.map { SIMD3<Double>(out[$0.x, $0.y]) }
        } else {
            recovered = scan.patchCentres.map { NegativeModel.sceneLinear(SIMD3<Double>(scan.image[$0.x, $0.y]), p) }
        }
        let truth = ColorChecker.rec2020.map(\.1)
        let k = truth[ColorChecker.middleGreyIndex].y / recovered[ColorChecker.middleGreyIndex].y
        recovered = recovered.map { $0 * k }

        var per: [(String, Double)] = []
        for (i, t) in truth.enumerated() {
            per.append((ColorChecker.rec2020[i].0, Lab.deltaE2000(Lab.lab(rec2020: t), Lab.lab(rec2020: recovered[i]))))
        }
        let worst = per.max { $0.1 < $1.1 }!
        return Result(mean: per.map(\.1).reduce(0, +) / Double(per.count), max: worst.1, worst: worst.0, perPatch: per)
    }

    /// Calibration from two neutral patches of the chart (white and black), i.e. the eyedropper workflow.
    static func greyPatchCalibration(_ scan: SyntheticScan, _ base: SIMD3<Double>) -> FilmCalibration {
        let lo = NegativeModel.density(SIMD3<Double>(scan.image[scan.patchCentres[23].x, scan.patchCentres[23].y]), base: base)
        let hi = NegativeModel.density(SIMD3<Double>(scan.image[scan.patchCentres[18].x, scan.patchCentres[18].y]), base: base)
        return FilmCalibration.from(shadow: lo, highlight: hi)
    }

    /// Fully automatic: the frame's statistics (neutral candidates over its density range) as a roll of one.
    static func automaticCalibration(_ scan: SyntheticScan, _ base: SIMD3<Double>) -> FilmCalibration {
        let proxy = AnalysisProxy(image: scan.image, sourceWidth: scan.image.width, sourceHeight: scan.image.height, clipLevel: [1, 1, 1], flat: nil)
        var f = FrameSettings()
        f.geometry.crop = CGRect(x: 0, y: scan.rebateRect.height, width: 1, height: 1 - scan.rebateRect.height)
        var roll = RollSettings()
        roll.filmBase = base
        Processor.measureAnchors(proxy, roll: roll, settings: &f)
        let st = f.stats!
        return Estimators.rollCalibration(stats: [st])
    }

    @Test func idealFilmIsRecoveredExactly() throws {
        let r = try Self.run(film: SyntheticFilm(), calibration: Self.greyPatchCalibration)
        print("ideal film, grey-patch calibration: \(r)")
        #expect(r.max < 0.01)
    }

    @Test func idealFilmAutomaticCalibration() throws {
        let r = try Self.run(film: SyntheticFilm(), calibration: Self.automaticCalibration)
        print("ideal film, automatic calibration: \(r)")
        #expect(r.mean < 0.5)
        #expect(r.max < 1.5)
    }

    @Test func gpuMatchesCPUOnRoundTrip() throws {
        let cpu = try Self.run(film: SyntheticFilm(), calibration: Self.greyPatchCalibration)
        let gpu = try Self.run(film: SyntheticFilm(), calibration: Self.greyPatchCalibration, gpu: true)
        print("GPU round trip: \(gpu)")
        #expect(gpu.max < 0.02)
        for (a, b) in zip(cpu.perPatch, gpu.perPatch) { #expect(abs(a.1 - b.1) < 0.02) }
    }

    /// Real films have a toe: the straight-line model can't be exact in the deepest shadows. This measures
    /// how much error that leaves (reported, with a loose bound), using different toe widths per layer.
    @Test func filmWithToeAndWrongGammaGuess() throws {
        var film = SyntheticFilm()
        film.toeWidth = [0.35, 0.45, 0.55]
        film.logEMin = log10(0.18) - 1.3
        let r = try Self.run(film: film, filmGamma: 0.6, calibration: Self.automaticCalibration)
        print("film with toe, automatic calibration: \(r)")
        for (name, e) in r.perPatch where e > 1 { print(String(format: "   %@: ΔE00 %.2f", name, e)) }
        #expect(r.mean < 3)
    }

    /// The neutral axis must stay neutral even when the overall film gamma guess is wrong
    /// (that only changes contrast, never colour).
    @Test func neutralsStayNeutralWithWrongGamma() throws {
        let film = SyntheticFilm()
        let scan = SyntheticScan(film: film)
        let base = film.rebate
        let cal = Self.greyPatchCalibration(scan, base)
        let p = ConversionParameters(filmBase: base, calibration: cal, referenceDensity: 1, filmGamma: 0.75, monochrome: false,
                                     monochromeWeights: [0.25, 0.5, 0.25], colorMatrix: ColorScience.sRGBToRec2020 * xe4CameraToSRGB,
                                     curve: PrintCurve().resolved)
        for i in 18...23 {
            let c = scan.patchCentres[i]
            let lab = Lab.lab(rec2020: NegativeModel.sceneLinear(SIMD3<Double>(scan.image[c.x, c.y]), p))
            #expect(hypot(lab.y, lab.z) < 0.05, "\(ColorChecker.sRGB8[i].0): a*=\(lab.y) b*=\(lab.z)")
        }
    }
}
