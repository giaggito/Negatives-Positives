import Foundation
import simd

/// A film stock (and, for negatives, a print paper) prepared for rendering. Built on the CPU once per
/// settings combination; the GPU kernel and the CPU reference (`renderPixel`) use exactly these numbers.
///
/// The model (after spektrafilm, Andrea Volpato):
///  1. Exposure. The scene colour becomes a smooth reflectance spectrum (Jakob–Hanika), lit by the film's
///     reference illuminant and integrated against each layer's measured spectral sensitivity:
///         E_c = ∫ R(λ) I_ref(λ) S_c(λ) dλ,   normalised so middle grey (18.4 %) gives E = 1.
///  2. Development. Density of each dye layer from the datasheet characteristic curves, with DIR-coupler
///     interlayer inhibition: log E′ = log E − Mᵀ · D_silver, then D = curve₀(log E′) where curve₀ is the
///     pre-coupler curve that makes grey ramps reproduce the datasheet exactly.
///  3. Spectral transmittance of the negative: T(λ) = 10^−(Σ D_c dye_c(λ) + base(λ)).
///  4. Printing (negatives): enlarger light through the negative onto the paper's three layers,
///         P_c = k_c ∫ L(λ) T(λ) S_paper,c(λ) dλ,
///     k balanced so middle grey prints neutral at 18.4 % (+ the user's filtration), paper density from the
///     paper's curves, print reflectance R(λ) = 10^−(Σ D′_c dye′_c(λ) + base′(λ)).
///  5. Viewing: reflectance (print) or transmittance (slide) under the viewing illuminant → XYZ → Rec.2020,
///     adapted so the paper (or clear film) is white.
public final class PreparedFilm: @unchecked Sendable {
    public struct Key: Hashable { var stock: String; var paper: String?; var warmth: Double; var tint: Double }

    public let stock: FilmStock
    public let paper: PrintPaper?
    public let kind: FilmStock.Kind
    public var isPositive: Bool { kind == .slide }
    /// Negative read by a lab scanner and inverted (instead of printed on paper).
    public let isScan: Bool
    /// Scan: film exposure → scene-linear Rec.2020 (inverse of the exposure model), developed density of middle
    /// grey and 1 / mid-tone gamma per layer, and the scanner's tone curve.
    public private(set) var scanInverse = matrix_identity_float3x3
    public private(set) var densityMid = SIMD3<Float>.zero
    public private(set) var invGamma = SIMD3<Float>(repeating: 1)
    public let scanCurve = ToneMath.printCurve(for: .standard)!.resolved
    /// Scanner channel weights per wavelength (Status M-like bands, normalised to the clear film base).
    public private(set) var scanWeights: [SIMD4<Float>] = []
    /// Scan saturation, set so the scan is as colourful as the same film printed on its usual paper.
    public private(set) var scanChroma: Float = 1
    /// Slides: below this OKLab lightness colour fades to neutral (projection flare and the eye's adaptation
    /// make the deepest shadows of a slide look black, though the light leaking between the dyes is purple).
    public static let slideBlackChroma: (Float, Float) = (0.15, 0.45)

    /// Exposure per unit (r+g+b) on the chromaticity grid, per layer.
    public private(set) var exposureLUT: [SIMD4<Float>]
    public let logEMin: Float, logEStep: Float
    /// Film density curves (min subtracted): original and before DIR couplers.
    public let curve: [SIMD4<Float>]
    public let preCouplerCurve: [SIMD4<Float>]
    public let couplerMatrixT: simd_float3x3
    public let densityMax: SIMD3<Float>
    /// Spectral tables, one entry per wavelength: (dye C, M, Y, base) of the film; print weights;
    /// (dye, base) of the paper; viewing weights (X, Y, Z).
    public let filmDyeBase: [SIMD4<Float>]
    public let printWeights: [SIMD4<Float>]
    public let paperDyeBase: [SIMD4<Float>]
    public let viewWeights: [SIMD4<Float>]
    public let paperCurve: [SIMD4<Float>]
    public let paperLogEMin: Float, paperLogEStep: Float
    /// Paper grade: gamma of the paper exposure about middle grey.
    public let paperGamma: Float
    public let outputMatrix: simd_float3x3

    private static var cache: [Key: PreparedFilm] = [:]
    private static let lock = NSLock()

    /// Prepared film for settings (cached). Nil when no stock is chosen.
    public static func prepare(_ s: FilmSettings) -> PreparedFilm? {
        guard let id = s.stock, let stock = FilmLibrary.shared.film(id) else { return nil }
        let paperID = stock.kind == .slide ? nil : (s.paper ?? "scan")
        let key = Key(stock: id, paper: paperID, warmth: s.warmth, tint: s.tint)
        lock.lock(); defer { lock.unlock() }
        if let p = cache[key] { return p }
        let p = PreparedFilm(stock: stock, paper: FilmLibrary.shared.paper(paperID), settings: s)
        if cache.count > 24 { cache.removeAll() }
        cache[key] = p
        return p
    }

    init(stock: FilmStock, paper: PrintPaper?, settings s: FilmSettings) {
        self.stock = stock
        self.kind = stock.kind
        let positive = stock.kind == .slide
        self.paper = positive ? nil : paper
        self.isScan = !positive && paper == nil
        let n = Spectral.count

        // 1. Exposure LUT over Rec.2020 chromaticity.
        let ref = Spectral.illuminant(stock.referenceIlluminant)
        let sens = stock.logSensitivity.map { SIMD3(pow(10, $0.x), pow(10, $0.y), pow(10, $0.z)) }
        var norm = SIMD3<Double>.zero
        for i in 0..<n { norm += 0.184 * ref[i] * sens[i] }
        let g = SpectralUpsampling.gridSize
        var lut = [SIMD4<Float>](repeating: .zero, count: g * g)
        var valid = [Bool](repeating: false, count: g * g)
        for i in 0..<g {
            for j in 0..<g {
                guard let t = SpectralUpsampling.target(i, j), let c = SpectralUpsampling.coefficients[i * g + j] else { continue }
                let r = SpectralUpsampling.reflectance(c)
                var e = SIMD3<Double>.zero
                for k in 0..<n { e += r[k] * ref[k] * sens[k] }
                let v = e / (t.x + t.y + t.z) / norm
                lut[i * g + j] = SIMD4(Float(v.x), Float(v.y), Float(v.z), 0)
                valid[i * g + j] = true
            }
        }
        // Outside the triangle: copy the nearest valid cell so bilinear lookups near the edge stay sane.
        for i in 0..<g {
            for j in 0..<g where !valid[i * g + j] {
                var best = (Int.max, 0)
                for a in 0..<g { for b in 0..<g where valid[a * g + b] { let d = (a - i) * (a - i) + (b - j) * (b - j); if d < best.0 { best = (d, a * g + b) } } }
                lut[i * g + j] = lut[best.1]
            }
        }
        exposureLUT = lut

        // 2. Curves (min subtracted) and DIR couplers.
        let logE = stock.logExposure
        logEMin = Float(logE.first!)
        logEStep = Float((logE.last! - logE.first!) / Double(logE.count - 1))
        let mins = stock.densityCurves.reduce(SIMD3<Double>(repeating: .infinity)) { simd_min($0, $1) }
        let curves = stock.densityCurves.map { $0 - mins }
        let dmax = curves.reduce(SIMD3<Double>(repeating: 0)) { simd_max($0, $1) }
        densityMax = SIMD3<Float>(dmax)
        // Coupler strength: the stock's. The pre-coupler inversion needs the
        // corrected exposure axis to stay increasing; very steep curves (slides) would fold it, so the
        // strength is reduced until it does — a model limit, not a physical one.
        var amount: Double = stock.kind == .bwNegative ? 0 : 1
        var pre = [SIMD4<Float>](repeating: .zero, count: logE.count)
        while amount > 0.01 {
            let m = Self.couplerMatrix() * amount
            var monotonic = true
            var built = [SIMD4<Float>](repeating: .zero, count: logE.count)
            for c in 0..<3 where monotonic {
                let x0 = (0..<logE.count).map { i -> Double in
                    let silver = positive ? dmax - curves[i] : curves[i]
                    return logE[i] - (m.transpose * silver)[c]
                }
                for i in 1..<x0.count where x0[i] <= x0[i - 1] { monotonic = false; break }
                guard monotonic else { break }
                let ys = curves.map { $0[c] }
                for i in 0..<logE.count { built[i][c] = Float(Self.interp(logE[i], x0, ys)) }
            }
            if monotonic { pre = built; break }
            amount *= 0.7
        }
        if amount <= 0.01 { amount = 0 }
        couplerMatrixT = simd_float3x3((Self.couplerMatrix() * amount).transpose)
        curve = curves.map { SIMD4(Float($0.x), Float($0.y), Float($0.z), 0) }
        preCouplerCurve = amount == 0 ? curve : pre

        // 3–5. Spectral tables.
        filmDyeBase = (0..<n).map { SIMD4(SIMD3<Float>(stock.dyeDensity[$0]), Float(stock.baseDensity[$0])) }
        let view = Spectral.illuminant(stock.kind == .slide ? stock.viewingIlluminant : (paper?.viewingIlluminant ?? "D50"))
        viewWeights = (0..<n).map { SIMD4(SIMD3<Float>(view[$0] * Spectral.cmf[$0]), 0) }
        let whiteBase = positive ? stock.baseDensity : (paper?.baseDensity ?? Array(repeating: 0, count: n))
        var white = SIMD3<Double>.zero
        for i in 0..<n { white += pow(10, -whiteBase[i]) * view[i] * Spectral.cmf[i] }
        outputMatrix = simd_float3x3(Spectral.toRec2020(adaptingFrom: white))

        if let paper, !positive {
            let lamp = Spectral.illuminant(paper.referenceIlluminant)
            printWeights = (0..<n).map { i in
                let ps = paper.logSensitivity[i]
                return SIMD4(Float(lamp[i] * pow(10, ps.x)), Float(lamp[i] * pow(10, ps.y)), Float(lamp[i] * pow(10, ps.z)), 0)
            }
            paperDyeBase = (0..<n).map { SIMD4(SIMD3<Float>(paper.dyeDensity[$0]), Float(paper.baseDensity[$0])) }
            let pmins = paper.densityCurves.reduce(SIMD3<Double>(repeating: .infinity)) { simd_min($0, $1) }
            paperCurve = paper.densityCurves.map { SIMD4(SIMD3<Float>($0 - pmins), 0) }
            paperLogEMin = Float(paper.logExposure.first!)
            paperLogEStep = Float((paper.logExposure.last! - paper.logExposure.first!) / Double(paper.logExposure.count - 1))
        } else {
            printWeights = []; paperDyeBase = []; paperCurve = []; paperLogEMin = 0; paperLogEStep = 1
        }
        paperGamma = 1
        let exposureGain: Float = 1

        // Balance: middle grey must come out neutral at 18.4 %.
        if positive {
            // Slide: one exposure gain so middle grey is projected at 18.4 % of the clear film.
            var lo = -6.0, hi = 6.0
            for _ in 0..<50 {
                let mid = (lo + hi) / 2
                let y = Double(ToneMath.lum(self.withBalance(gain: Float(pow(2, mid)), logK: .zero, mid: .zero).renderPixelNoBalance(SIMD3(repeating: 0.184))))
                if y < 0.184 { lo = mid } else { hi = mid }
            }
            balanced = (Float(pow(2, (lo + hi) / 2)), .zero, .zero)
            // Colour-compensating filtration on the camera (as slide shooters used CC filters): per-layer
            // exposure factors so middle grey projects neutral. The rest of the film's colour is untouched.
            let base = exposureLUT
            var cc = SIMD3<Double>.zero
            func apply(_ c: SIMD3<Double>) {
                let f = SIMD4<Float>(Float(pow(10, c.x)), Float(pow(10, c.y)), Float(pow(10, c.z)), 1)
                exposureLUT = base.map { $0 * f }
            }
            for _ in 0..<30 {
                apply(cc)
                let f0 = SIMD3<Double>(renderPixelNoBalance(SIMD3(repeating: 0.184))) - 0.184
                if simd_length(f0) < 1e-7 { break }
                var j = simd_double3x3()
                for c in 0..<3 {
                    var d = cc; d[c] += 1e-4
                    apply(d)
                    j[c] = (SIMD3<Double>(renderPixelNoBalance(SIMD3(repeating: 0.184))) - 0.184 - f0) / 1e-4
                }
                guard abs(j.determinant) > 1e-14 else { break }
                cc -= j.inverse * f0
            }
            apply(cc)
        } else if isScan {
            // Scanned negative: the scanner normalises on middle grey (see prepareScanAndShadows).
            balanced = (exposureGain, .zero, .zero)
        } else {
            // Negative: Newton on the three print-exposure offsets (log10). The negative is exposed with the
            // user's over/under exposure and the print compensates (the negative's density changes, not the
            // print's brightness).
            balanced = (exposureGain, .zero, .zero)
            var k = SIMD3<Double>.zero
            // Start: put middle grey at the middle of the paper's exposure range.
            let p0 = SIMD3<Double>(self.paperExposure(SIMD3(repeating: 0.184), logK: .zero))
            let pd = paperCurve.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            let pmax = pd.reduce(SIMD3<Double>(repeating: 0)) { simd_max($0, $1) }
            for c in 0..<3 {
                // log exposure where the paper reaches 45 % of its maximum density
                let target = 0.45 * pmax[c]
                var x = Double(paperLogEMin)
                for (i, d) in pd.enumerated() where d[c] >= target { x = Double(paperLogEMin) + Double(i) * Double(paperLogEStep); break }
                k[c] = x - log10(max(p0[c], 1e-12))
            }
            if stock.kind == .bwNegative {
                // Neutral silver image: one print exposure for all three (identical) layers.
                var lo = k.x - 4, hi = k.x + 4
                for _ in 0..<60 {
                    let m = (lo + hi) / 2
                    let y = Double(ToneMath.lum(self.renderNegative(SIMD3(repeating: 0.184), logK: SIMD3<Float>(repeating: Float(m)))))
                    if y > 0.184 { lo = m } else { hi = m }      // more print exposure = darker print
                }
                k = SIMD3(repeating: (lo + hi) / 2)
            }
            for _ in 0..<(stock.kind == .bwNegative ? 0 : 30) {
                let f = SIMD3<Double>(self.renderNegative(SIMD3(repeating: 0.184), logK: SIMD3<Float>(k))) - 0.184
                if simd_length(f) < 1e-7 { break }
                var j = simd_double3x3()
                for c in 0..<3 {
                    var dk = k; dk[c] += 1e-4
                    let f2 = SIMD3<Double>(self.renderNegative(SIMD3(repeating: 0.184), logK: SIMD3<Float>(dk))) - 0.184
                    j[c] = (f2 - f) / 1e-4
                }
                guard abs(j.determinant) > 1e-14 else { break }
                k -= j.inverse * f
            }
            // The user's filtration on top of the neutral balance (more blue light = more yellow dye = warmer).
            if stock.kind != .bwNegative {
                k.z += 0.12 * s.warmth / 100
                k.y += 0.12 * s.tint / 100
                k.x += 0.04 * s.warmth / 100
            }
            // Middle grey's paper log exposure, the pivot of the paper grade.
            let mid = simd_float3(log10Safe(SIMD3<Double>(self.paperExposure(SIMD3<Float>(repeating: 0.184), logK: SIMD3<Float>(k)))))
            balanced = (exposureGain, SIMD3<Float>(k), mid)
        }
        prepareScanAndShadows(negativeExposure: exposureGain)
    }

    /// Lab-scan inversion data (negatives) and the slide shadow neutralisation.
    private func prepareScanAndShadows(negativeExposure gain: Float) {
        let grey = SIMD3<Float>(repeating: 0.184)
        if isPositive {
            densityMid = develop(exposure(grey) * balanced.gain)
            return
        }
        guard isScan else { return }
        // Linear map scene RGB → film exposure, least squares over colours inside sRGB.
        var ata = simd_double3x3(), atb = simd_double3x3()
        let m = simd_float3x3(ColorScience.sRGBToRec2020)
        for r in stride(from: 0.0, through: 1.0, by: 0.125) {
            for g in stride(from: 0.0, through: 1.0, by: 0.125) {
                for b in stride(from: 0.0, through: 1.0, by: 0.125) where r + g + b > 0.1 {
                    let rgb = m * SIMD3<Float>(Float(r), Float(g), Float(b)) * 0.184
                    let e = SIMD3<Double>(exposure(rgb))
                    let x = SIMD3<Double>(rgb)
                    ata += simd_double3x3(columns: (x * x.x, x * x.y, x * x.z))
                    atb += simd_double3x3(columns: (e * x.x, e * x.y, e * x.z))
                }
            }
        }
        if kind == .bwNegative {
            // Identical layers: a neutral scan (mean of the layers).
            let k = Float(0.184 / 3)
            scanInverse = simd_float3x3(SIMD3(repeating: k), SIMD3(repeating: k), SIMD3(repeating: k))
        } else {
            let toE = atb * ata.inverse               // E ≈ toE · rgb
            var inv = toE.inverse
            // Exact neutrality: middle grey (E = 1 in every layer) scans to 0.184 grey.
            let v = inv * SIMD3<Double>(repeating: 1)
            inv = simd_double3x3(diagonal: SIMD3(repeating: 0.184) / v) * inv
            scanInverse = simd_float3x3(inv)
        }
        // Like a lab scanner, normalise on middle grey of this negative (over / under exposure changes the
        // negative's character — compression, shadow detail — not the brightness of the scan).
        // The scanner reads transmitted light in three bands (Status M-like: 445, 535, 640 nm), so it sees the
        // dyes' overlapping absorptions and the orange mask; it is calibrated on the clear film base.
        let wl = Spectral.wavelengths
        func band(_ c: Double, _ fwhm: Double) -> [Double] { wl.map { exp(-0.5 * pow(($0 - c) / (fwhm / 2.355), 2)) } }
        let bands = [band(640, 40), band(535, 32), band(445, 30)]
        var w = (0..<Spectral.count).map { i in SIMD4<Float>(Float(bands[0][i]), Float(bands[1][i]), Float(bands[2][i]), 0) }
        var base = SIMD4<Float>.zero
        for i in 0..<Spectral.count { base += pow(10, -filmDyeBase[i].w) * w[i] }
        w = w.map { $0 / SIMD4(base.x, base.y, base.z, 1) }
        scanWeights = w
        let eMid = exposure(grey) * balanced.gain
        densityMid = scanDensity(develop(eMid))
        let lo = scanDensity(develop(eMid * pow(10, -0.05))), hi = scanDensity(develop(eMid * pow(10, 0.05)))
        let gamma = (hi - lo) / 0.1
        invGamma = SIMD3(1 / max(gamma.x, 0.05), 1 / max(gamma.y, 0.05), 1 / max(gamma.z, 0.05))
        // Calibrate the scanner's saturation on the darkroom print of the same negative (Kodak / Fuji designed
        // these films for their papers): ratio of mean OKLab chroma over a ColorChecker-like set of colours.
        if kind != .bwNegative, let paperID = stock.defaultPaper, let paper = FilmLibrary.shared.paper(paperID) {
            var ps = FilmSettings(); ps.stock = stock.id; ps.paper = paperID
            let print = PreparedFilm(stock: stock, paper: paper, settings: ps)
            let patches: [SIMD3<Float>] = [
                [0.45, 0.32, 0.27], [0.75, 0.58, 0.50], [0.38, 0.48, 0.61], [0.35, 0.42, 0.27], [0.51, 0.50, 0.69], [0.40, 0.74, 0.67],
                [0.84, 0.48, 0.17], [0.31, 0.36, 0.65], [0.76, 0.33, 0.38], [0.36, 0.24, 0.42], [0.62, 0.74, 0.25], [0.88, 0.63, 0.18],
                [0.17, 0.24, 0.58], [0.27, 0.58, 0.29], [0.69, 0.20, 0.23], [0.93, 0.78, 0.12], [0.73, 0.33, 0.58], [0.0, 0.52, 0.65],
            ]
            var cs: Float = 0, cp: Float = 0
            let m = simd_float3x3(ColorScience.sRGBToRec2020)
            for e in patches {
                let lin = m * SIMD3<Float>(Float(OutputColorSpace.sRGB.decode(Double(e.x))), Float(OutputColorSpace.sRGB.decode(Double(e.y))), Float(OutputColorSpace.sRGB.decode(Double(e.z))))
                let a = ToneMath.oklab(simd_max(scan(develop(exposure(lin) * balanced.gain)), .zero))
                let b = ToneMath.oklab(simd_max(print.renderPixel(lin), .zero))
                cs += simd_length(SIMD2(a.y, a.z)); cp += simd_length(SIMD2(b.y, b.z))
            }
            if cs > 1e-4 { scanChroma = min(max(cp / cs, 0.4), 1.2) }
        }
    }

    // Balance state set during init (stored separately so the helper render functions can be used before it).
    private var balanced: (gain: Float, logK: SIMD3<Float>, mid: SIMD3<Float>) = (1, .zero, .zero)
    public var gain: Float { balanced.gain }
    public var logK: SIMD3<Float> { balanced.logK }
    public var mid: SIMD3<Float> { balanced.mid }

    private func withBalance(gain: Float, logK: SIMD3<Float>, mid: SIMD3<Float>) -> PreparedFilm {
        balanced = (gain, logK, mid)
        return self
    }

    static func couplerMatrix() -> simd_double3x3 {
        // spektrafilm defaults. Row = donor layer (R, G, B), column = receiving layer: same-layer gammas on the
        // diagonal, interlayer inhibition off it. The correction to a layer's log exposure is (Mᵀ · D)_receiver.
        simd_double3x3(rows: [
            SIMD3(0.341, 0.355, 0.305),
            SIMD3(0.154, 0.324, 0.358),
            SIMD3(0.171, 0.225, 0.273),
        ])
    }

    static func interp(_ x: Double, _ xs: [Double], _ ys: [Double]) -> Double {
        if x <= xs[0] { return ys[0] }
        if x >= xs[xs.count - 1] { return ys[ys.count - 1] }
        var lo = 0, hi = xs.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if xs[m] <= x { lo = m } else { hi = m } }
        let t = (x - xs[lo]) / max(xs[hi] - xs[lo], 1e-12)
        return ys[lo] + (ys[hi] - ys[lo]) * t
    }

    // MARK: CPU reference (mirrors the GPU kernel; no grain, halation or bloom)

    @inline(__always) static func lookup(_ table: [SIMD4<Float>], _ x: Float, min: Float, step: Float, channel c: Int) -> Float {
        let f = (x - min) / step
        if f <= 0 { return table[0][c] }
        let n = table.count
        if f >= Float(n - 1) { return table[n - 1][c] }
        let i = Int(f)
        let t = f - Float(i)
        return table[i][c] + (table[i + 1][c] - table[i][c]) * t
    }

    /// Film exposure (per layer) of a scene colour, before the exposure gain.
    public func exposure(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_max(rgb, .zero)
        let s = c.x + c.y + c.z
        guard s > 1e-10 else { return .zero }
        let g = Float(SpectralUpsampling.gridSize - 1)
        let x = c.x / s * g, y = c.y / s * g
        let i = min(Int(x), SpectralUpsampling.gridSize - 2), j = min(Int(y), SpectralUpsampling.gridSize - 2)
        let tx = x - Float(i), ty = y - Float(j)
        let n = SpectralUpsampling.gridSize
        func at(_ a: Int, _ b: Int) -> SIMD3<Float> { let v = exposureLUT[a * n + b]; return SIMD3(v.x, v.y, v.z) }
        let v = (at(i, j) * (1 - ty) + at(i, j + 1) * ty) * (1 - tx) + (at(i + 1, j) * (1 - ty) + at(i + 1, j + 1) * ty) * tx
        return v * s
    }

    /// Developed film density (per layer, above base) for a per-layer exposure.
    public func develop(_ e: SIMD3<Float>) -> SIMD3<Float> {
        var logE = SIMD3<Float>(log10(max(e.x, 1e-10)), log10(max(e.y, 1e-10)), log10(max(e.z, 1e-10)))
        var d0 = SIMD3<Float>.zero
        for c in 0..<3 { d0[c] = Self.lookup(curve, logE[c], min: logEMin, step: logEStep, channel: c) }
        let silver = isPositive ? densityMax - d0 : d0
        logE -= couplerMatrixT * silver
        var d = SIMD3<Float>.zero
        for c in 0..<3 { d[c] = Self.lookup(preCouplerCurve, logE[c], min: logEMin, step: logEStep, channel: c) }
        return d
    }

    /// Slide shadows fade to neutral below `slideBlackChroma` (see there).
    public static func neutralBlacks(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var lab = ToneMath.oklab(simd_max(c, .zero))
        let (a, b) = slideBlackChroma
        let t = min(max((lab.x - a) / (b - a), 0), 1)
        let k = t * t * (3 - 2 * t)
        lab.y *= k; lab.z *= k
        return ToneMath.fromOklab(lab)
    }

    /// Densities the scanner measures (relative to the film base) for dye densities `d`.
    public func scanDensity(_ d: SIMD3<Float>) -> SIMD3<Float> {
        var r = SIMD3<Float>.zero
        for i in 0..<Spectral.count {
            let dy = filmDyeBase[i]
            let t = pow(10, -(d.x * dy.x + d.y * dy.y + d.z * dy.z + dy.w))
            r += t * SIMD3(scanWeights[i].x, scanWeights[i].y, scanWeights[i].z)
        }
        return SIMD3(-log10(max(r.x, 1e-10)), -log10(max(r.y, 1e-10)), -log10(max(r.z, 1e-10)))
    }

    /// Lab scan: measured density → film-referred scene light (undoing the film's mid-tone gamma, keeping its
    /// toe, shoulder and colour) → the scanner's tone curve per channel.
    public func scan(_ dye: SIMD3<Float>) -> SIMD3<Float> {
        let d = scanDensity(dye)
        let ex = SIMD3<Float>(pow(10, (d.x - densityMid.x) * invGamma.x), pow(10, (d.y - densityMid.y) * invGamma.y), pow(10, (d.z - densityMid.z) * invGamma.z))
        let rgb = scanInverse * ex
        let t = SIMD3(ToneMath.printCurve(rgb.x, scanCurve), ToneMath.printCurve(rgb.y, scanCurve), ToneMath.printCurve(rgb.z, scanCurve))
        guard scanChroma != 1 else { return t }
        var lab = ToneMath.oklab(t)
        lab.y *= scanChroma; lab.z *= scanChroma
        return ToneMath.fromOklab(lab)
    }

    /// Paper exposure (linear, per layer) from film density, before the balance.
    func paperExposureFromDensity(_ d: SIMD3<Float>, logK: SIMD3<Float>) -> SIMD3<Float> {
        var p = SIMD3<Float>.zero
        for i in 0..<Spectral.count {
            let dy = filmDyeBase[i]
            let t = pow(10, -(d.x * dy.x + d.y * dy.y + d.z * dy.z + dy.w))
            p += t * SIMD3(printWeights[i].x, printWeights[i].y, printWeights[i].z)
        }
        return p * SIMD3(pow(10, logK.x), pow(10, logK.y), pow(10, logK.z))
    }

    func paperExposure(_ rgb: SIMD3<Float>, logK: SIMD3<Float>) -> SIMD3<Float> {
        paperExposureFromDensity(develop(exposure(rgb) * balanced.gain), logK: logK)
    }

    /// Print / slide density (per layer) → display-linear Rec.2020.
    func view(density: SIMD3<Float>, dyeBase: [SIMD4<Float>]) -> SIMD3<Float> {
        var xyz = SIMD3<Float>.zero
        for i in 0..<Spectral.count {
            let dy = dyeBase[i]
            let r = pow(10, -(density.x * dy.x + density.y * dy.y + density.z * dy.z + dy.w))
            xyz += r * SIMD3(viewWeights[i].x, viewWeights[i].y, viewWeights[i].z)
        }
        return outputMatrix * xyz
    }

    func paperDensity(_ p: SIMD3<Float>) -> SIMD3<Float> {
        var out = SIMD3<Float>.zero
        for c in 0..<3 {
            var lp = log10(max(p[c], 1e-10))
            lp = (lp - balanced.mid[c]) * paperGamma + balanced.mid[c]
            out[c] = Self.lookup(paperCurve, lp, min: paperLogEMin, step: paperLogEStep, channel: c)
        }
        return out
    }

    func renderNegative(_ rgb: SIMD3<Float>, logK: SIMD3<Float>) -> SIMD3<Float> {
        let p = paperExposure(rgb, logK: logK)
        var out = SIMD3<Float>.zero
        for c in 0..<3 {
            out[c] = Self.lookup(paperCurve, log10(max(p[c], 1e-10)), min: paperLogEMin, step: paperLogEStep, channel: c)
        }
        return view(density: out, dyeBase: paperDyeBase)
    }

    fileprivate func renderPixelNoBalance(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        view(density: develop(exposure(rgb) * balanced.gain), dyeBase: filmDyeBase)
    }

    /// Scene-linear Rec.2020 → display-linear Rec.2020 through film (and paper). CPU reference.
    public func renderPixel(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let d = develop(exposure(rgb) * balanced.gain)
        return printOrView(d)
    }

    /// Film density → displayed colour (print for negatives, projection for slides).
    public func printOrView(_ d: SIMD3<Float>) -> SIMD3<Float> {
        if isPositive { return Self.neutralBlacks(view(density: d, dyeBase: filmDyeBase)) }
        if isScan { return scan(d) }
        return view(density: paperDensity(paperExposureFromDensity(d, logK: balanced.logK)), dyeBase: paperDyeBase)
    }
}

private func log10Safe(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(log10(max(v.x, 1e-12)), log10(max(v.y, 1e-12)), log10(max(v.z, 1e-12))) }

extension PreparedFilm: Equatable {
    public static func == (a: PreparedFilm, b: PreparedFilm) -> Bool { a === b }
}
