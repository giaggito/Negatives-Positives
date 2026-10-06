import Foundation
import simd

public enum Statistics {
    /// Linear-interpolated percentile of an already sorted array, p ∈ [0, 1].
    public static func percentile(sorted v: [Double], _ p: Double) -> Double {
        precondition(!v.isEmpty)
        let pos = min(max(p, 0), 1) * Double(v.count - 1)
        let i = Int(pos), f = pos - Double(i)
        return i + 1 < v.count ? v[i] * (1 - f) + v[i + 1] * f : v[i]
    }

    public static func median(_ v: [Double]) -> Double { percentile(sorted: v.sorted(), 0.5) }

    public static func median(_ v: [SIMD3<Double>]) -> SIMD3<Double> {
        SIMD3(median(v.map(\.x)), median(v.map(\.y)), median(v.map(\.z)))
    }

    public static func weightedMedian(_ values: [Double], weights: [Double]) -> Double {
        precondition(values.count == weights.count && !values.isEmpty)
        let pairs = zip(values, weights).sorted { $0.0 < $1.0 }
        let total = weights.reduce(0, +)
        guard total > 0 else { return median(values) }
        var acc = 0.0
        for (v, w) in pairs {
            acc += w
            if acc >= total / 2 { return v }
        }
        return pairs.last!.0
    }
}

/// Automatic measurements. All of them are run once and their results stored in the settings, so that
/// preview and export (and every later session) use exactly the same numbers.
public enum Estimators {

    // MARK: Film base

    public struct FilmBaseMeasurement: Codable, Equatable, Sendable {
        public var base: SIMD3<Double>
        /// Fraction of samples at or above 98% of the sensor clip level: >0 means the scan is overexposed
        /// and the base (and the thinnest shadows) lost information.
        public var clippedFraction: Double
    }

    /// Robust per-channel median of the samples inside the rebate rectangle.
    public static func filmBase(samples: [SIMD3<Double>], clipLevel: SIMD3<Double>) -> FilmBaseMeasurement? {
        guard !samples.isEmpty else { return nil }
        let clipped = samples.filter { any($0 .>= clipLevel * 0.98) }.count
        return FilmBaseMeasurement(base: Statistics.median(samples), clippedFraction: Double(clipped) / Double(samples.count))
    }

    /// Automatic film-base estimate when no rebate rectangle is given.
    ///
    /// The film base is the brightest thing on a negative that is *still film*. `cells` are medians of small
    /// tiles over the whole sensor (so dust and grain don't matter). We discard:
    ///  - clipped tiles,
    ///  - for colour film, near-neutral tiles: light coming through sprocket holes or around the film is the
    ///    bare (roughly daylight, hence neutral after the fixed multipliers) panel, while the base is orange,
    ///  - tiles far brighter than the bulk of the bright tiles (holes on B&W film, where chroma can't help).
    /// and take the median of the brightest 2% that remain. If no rebate is visible this returns the
    /// thinnest part of the image, a few hundredths of density above the true base; the neutral-lock
    /// calibration absorbs such a constant offset, so the final colours are unaffected.
    public static func autoFilmBase(cells: [SIMD3<Double>], clipLevel: SIMD3<Double>, colorFilm: Bool) -> FilmBaseMeasurement? {
        var c = cells.filter { all($0 .> 0) && all($0 .< clipLevel * 0.98) }
        let clippedFraction = Double(cells.count - c.count) / Double(max(cells.count, 1))
        if colorFilm {
            let film = c.filter { v in
                let rg = log10(v.x / v.y), bg = log10(v.z / v.y)
                return !(abs(rg) < 0.06 && abs(bg) < 0.06)
            }
            if film.count >= max(8, c.count / 10) { c = film }
        }
        guard c.count >= 4 else { return nil }
        c.sort { $0.y > $1.y }
        let p95 = c[min(c.count - 1, c.count / 20)].y
        let bulk = c.filter { $0.y <= p95 * 1.25 }
        let top = Array(bulk.prefix(max(3, bulk.count / 50)))
        return FilmBaseMeasurement(base: Statistics.median(top), clippedFraction: clippedFraction)
    }

    /// Plausible limits for the gamma ratio of a layer relative to green.
    public static let gammaRatioLimits = 0.5...2.0
}

// MARK: - Frame statistics (version 2 analysis)

/// What a frame contributes to the automatic conversion, measured once on its picture (never on the holder,
/// light table, rebate or sprocket holes — see `FrameDetector`).
///
/// - `neutrals`: at several density levels, where the most neutral-looking areas of the frame lie, as raw
///   base-normalised density differences (R − G, B − G). Unexposed film is the base itself, so a neutral grey
///   lies on a line through the origin: D_R = r·D_G (+ a tiny fog term). The slope r (the layers' gamma ratio)
///   is fitted to these points over the whole roll — a colourful subject shifts the points sideways, which the
///   fit's small intercept absorbs, instead of tilting the colour of every tone as two extreme samples would.
/// - `average`: centre-weighted mean density of the picture (per channel). Like a lab printer's large-area
///   density, it sets each frame's exposure; extremes (a sunlit sky, a black holder) can't drag it.
public struct FrameStats: Codable, Equatable, Sendable {
    public struct Neutral: Codable, Equatable, Sendable {
        /// Green density, the cluster's (R − G, B − G), its share of the band's pixels, and the band.
        public var g: Double, dr: Double, db: Double, weight: Double
        public var band: Int = 0
    }
    public var neutrals: [Neutral]
    public var average: SIMD3<Double>
    /// The picture's bright tones: densities around the 90th percentile (green). A camera's meter and a
    /// photographer's eye place these consistently, far more so than the average (a big sky or a dark
    /// interior moves the average by stops). Nil in statistics from older versions.
    public var bright: SIMD3<Double>?
    /// 0.5 % and 99.5 % density bands (diagnostics, B&W range).
    public var shadow: SIMD3<Double>, highlight: SIMD3<Double>
    /// Picture area found on the scan (normalised sensor coordinates), if any.
    public var picture: CGRect?
    public var range: Double { max(highlight.y - shadow.y, 0) }
}

extension Estimators {
    /// Frame statistics from base-normalised density samples of picture pixels, each with a centre weight.
    public static func frameStats(densities d: [SIMD3<Double>], centreWeights cw: [Double], picture: CGRect?) -> FrameStats? {
        guard d.count >= 400 else { return nil }
        // Centre-weighted mean density.
        var acc = SIMD3<Double>.zero, ws = 0.0
        for (v, w) in zip(d, cw) { acc += v * w; ws += w }
        let average = acc / max(ws, 1e-9)
        let order = d.indices.sorted { d[$0].y < d[$1].y }
        func band(_ a: Double, _ b: Double) -> [SIMD3<Double>] {
            let i0 = Int(Double(order.count - 1) * a), i1 = max(i0 + 1, Int(Double(order.count - 1) * b))
            return order[i0..<min(i1, order.count)].map { d[$0] }
        }
        let shadow = Statistics.median(band(0.001, 0.01)), highlight = Statistics.median(band(0.99, 0.999))
        // Neutral candidates: in each density band, the strongest clusters on the (R−G, B−G) plane (peaks of a
        // smoothed histogram, refined by mean-shift). Which cluster is the neutral one is decided later, over the
        // whole roll: the one set of candidates that lines up through the origin.
        var neutrals: [FrameStats.Neutral] = []
        let bands: [(Double, Double)] = [(0.03, 0.15), (0.15, 0.3), (0.3, 0.45), (0.45, 0.6), (0.6, 0.75), (0.75, 0.88), (0.88, 0.97)]
        for (bi, (a, b)) in bands.enumerated() {
            let sm = band(a, b)
            guard sm.count >= 50 else { continue }
            let c = sm.map { SIMD2($0.x - $0.y, $0.z - $0.y) }
            for (m, share, g) in Self.clusters(c, values: sm.map(\.y), count: 5) {
                neutrals.append(.init(g: g, dr: m.x, db: m.y, weight: share, band: bi))
            }
        }
        return FrameStats(neutrals: neutrals, average: average, bright: Statistics.median(band(0.87, 0.93)),
                          shadow: shadow, highlight: highlight, picture: picture)
    }


    /// The strongest clusters of 2-D points: peaks of a smoothed histogram (bins 0.02), refined by mean-shift,
    /// with the share of the points within 0.06 of each and the mean of `values` over those points (the
    /// cluster's own green density — the band's would misplace it along the path).
    static func clusters(_ c: [SIMD2<Double>], values: [Double], count: Int) -> [(SIMD2<Double>, Double, Double)] {
        let bin = 0.02, half = 40
        var hist = [Double](repeating: 0, count: (2 * half) * (2 * half))
        for v in c {
            let i = Int(floor(v.x / bin)) + half, j = Int(floor(v.y / bin)) + half
            if i >= 0, j >= 0, i < 2 * half, j < 2 * half { hist[j * 2 * half + i] += 1 }
        }
        // Smooth (σ ≈ 1.5 bins, separable 7-tap).
        let k: [Double] = [0.04, 0.11, 0.21, 0.28, 0.21, 0.11, 0.04]
        func blur(_ h: [Double], horizontal: Bool) -> [Double] {
            var o = h
            for j in 0..<(2 * half) {
                for i in 0..<(2 * half) {
                    var acc = 0.0
                    for t in -3...3 {
                        let ii = horizontal ? i + t : i, jj = horizontal ? j : j + t
                        if ii >= 0, jj >= 0, ii < 2 * half, jj < 2 * half { acc += k[t + 3] * h[jj * 2 * half + ii] }
                    }
                    o[j * 2 * half + i] = acc
                }
            }
            return o
        }
        let sh = blur(blur(hist, horizontal: true), horizontal: false)
        var peaks: [(Int, Int, Double)] = []
        for j in 1..<(2 * half - 1) {
            for i in 1..<(2 * half - 1) {
                let v = sh[j * 2 * half + i]
                guard v > 0 else { continue }
                var isMax = true
                for dj in -1...1 { for di in -1...1 where (di, dj) != (0, 0) && sh[(j + dj) * 2 * half + i + di] > v { isMax = false } }
                if isMax { peaks.append((i, j, v)) }
            }
        }
        peaks.sort { $0.2 > $1.2 }
        var out: [(SIMD2<Double>, Double, Double)] = []
        for p in peaks.prefix(count * 3) {
            var m = SIMD2((Double(p.0 - half) + 0.5) * bin, (Double(p.1 - half) + 0.5) * bin)
            for sigma in [0.04, 0.03] {
                var sum = SIMD2<Double>.zero, ws = 0.0
                for v in c { let w = exp(-simd_length_squared(v - m) / (2 * sigma * sigma)); sum += v * w; ws += w }
                if ws > 0 { m = sum / ws }
            }
            guard !out.contains(where: { simd_length($0.0 - m) < 0.05 }) else { continue }
            var n = 0, vs = 0.0
            for (k, v) in c.enumerated() where simd_length(v - m) < 0.06 { n += 1; vs += values[k] }
            let share = Double(n) / Double(c.count)
            guard share > 0.03 else { continue }
            out.append((m, share, vs / Double(n)))
            if out.count == count { break }
        }
        return out
    }

    /// Roll calibration from every frame's neutral candidates. A neutral grey lies on a line through the origin
    /// (unexposed film is the base itself): (D_R − D_G, D_B − D_G) = (s_R, s_B)·D_G. The slopes are found by a
    /// search over all lines, where each density band of each frame votes once, for its candidate closest to the
    /// line (so a colourful subject — foliage, a blue sky — can't outvote the greys that line up across tones),
    /// then refined by least squares on those candidates with a small intercept allowed (fog, a base taken
    /// from the thinnest picture area).
    /// Whether the base was seen on clear film: then the darkest parts of the pictures lie clearly above it.
    /// When every frame's thinnest areas sit at the base, the base was taken from the picture itself.
    public static func baseIsClearFilm(_ stats: [FrameStats]) -> Bool {
        !stats.isEmpty && stats.allSatisfy { $0.shadow.y > 0.03 }
    }

    public static func rollCalibration(stats: [FrameStats]) -> FilmCalibration {
        // Groups: one per (frame, band).
        var groups: [[FrameStats.Neutral]] = []
        for s in stats {
            for b in Set(s.neutrals.map(\.band)).sorted() { groups.append(s.neutrals.filter { $0.band == b }) }
        }
        guard !groups.isEmpty else { return .identity }
        let sigma = 0.035, prior = 0.25
        func score(_ sr: Double, _ sb: Double) -> Double {
            var total = 0.0
            for gp in groups {
                var best = 0.0
                for p in gp {
                    let e = (p.dr - sr * p.g) * (p.dr - sr * p.g) + (p.db - sb * p.g) * (p.db - sb * p.g)
                    best = max(best, p.weight.squareRoot() * exp(-e / (2 * sigma * sigma)))
                }
                total += best
            }
            return total * exp(-(sr * sr + sb * sb) / (2 * prior * prior))
        }
        var best = (score(0, 0), 0.0, 0.0)
        for i in -50...50 {
            for j in -50...50 {
                let sr = Double(i) / 100, sb = Double(j) / 100
                let v = score(sr, sb)
                if v > best.0 { best = (v, sr, sb) }
            }
        }
        // Refine: per group the candidate nearest the line; weighted least squares with a held intercept.
        let chosen: [FrameStats.Neutral] = groups.compactMap { gp in
            gp.min { a, b in
                let ea = pow(a.dr - best.1 * a.g, 2) + pow(a.db - best.2 * a.g, 2)
                let eb = pow(b.dr - best.1 * b.g, 2) + pow(b.db - best.2 * b.g, 2)
                return ea < eb
            }
        }.filter { pow($0.dr - best.1 * $0.g, 2) + pow($0.db - best.2 * $0.g, 2) < pow(3 * sigma, 2) }
        func fit(_ y: (FrameStats.Neutral) -> Double, _ s0: Double) -> (r: Double, k: Double) {
            guard chosen.count >= 2 else { return (1 + s0, 0) }
            let lambdaS = 0.002, lambdaK = 0.3
            let total = chosen.map { $0.weight.squareRoot() }.reduce(0, +)
            var a11 = lambdaS, a12 = 0.0, a22 = lambdaK, b1 = lambdaS * s0, b2 = 0.0
            for p in chosen {
                let w = p.weight.squareRoot() / total
                a11 += w * p.g * p.g; a12 += w * p.g; a22 += w
                b1 += w * p.g * y(p); b2 += w * y(p)
            }
            let det = a11 * a22 - a12 * a12
            guard abs(det) > 1e-12 else { return (1 + s0, 0) }
            let s = (b1 * a22 - b2 * a12) / det, k = (a11 * b2 - a12 * b1) / det
            return (min(max(1 + s, gammaRatioLimits.lowerBound), gammaRatioLimits.upperBound), k)
        }
        let r = fit({ $0.dr }, best.1), b = fit({ $0.db }, best.2)
        // e_c = D_c / r_c − o_c is neutral when D_c = r_c·D_G + k_c  →  o_c = k_c / r_c.
        var cal = FilmCalibration(gammaRatio: SIMD3(r.r, 1, b.r), offset: SIMD3(r.k / r.r, 0, b.k / b.r))
        let path = rollPath(stats: stats, anchored: baseIsClearFilm(stats))
        if path.count >= 3 { cal.neutral = path }
        return cal
    }

    /// A frame's neutral path: through its density bands from the base (0, 0) upwards, the sequence of
    /// candidates that best combines support (share of the band's pixels) with smoothness (moderate slope,
    /// little bending) — found exactly by dynamic programming. Greys line up smoothly from the base; a
    /// colourful subject sits off to the side and would need a jump.
    /// `anchored`: the path starts at the base (0, 0) — true when the base was measured on clear film. When it
    /// was taken from the picture's own thinnest part (a tightly cropped scan), the base is only a guess, and the
    /// path starts freely at its first measured point.
    public static func framePath(_ s: FrameStats, anchored: Bool = true) -> [FrameStats.Neutral] {
        let bands = Set(s.neutrals.map(\.band)).sorted()
        let layers = bands.map { b in s.neutrals.filter { $0.band == b } }.filter { !$0.isEmpty }
        guard !layers.isEmpty else { return [] }
        let origin = FrameStats.Neutral(g: 0, dr: 0, db: 0, weight: 1, band: -1)
        func slope(_ a: FrameStats.Neutral, _ b: FrameStats.Neutral) -> SIMD2<Double> {
            SIMD2(b.dr - a.dr, b.db - a.db) / max(b.g - a.g, 0.04)
        }
        let slopeScale = 0.45, bendScale = 0.6
        // Where neutrals of real stocks fall (spectral bench: 9 colour stocks × 3 camera sensitivities × 3 lights):
        // R − G ≈ −0.13·D_G and B − G ≈ +0.12·D_G, give or take 0.12 — a gentle preference that keeps a blue sky
        // or green foliage cluster (far outside that range) from passing for grey.
        func prior(_ c: FrameStats.Neutral) -> Double {
            let d = SIMD2(c.dr + 0.13 * c.g, c.db - 0.12 * c.g)
            return simd_length_squared(d) / (2 * 0.12 * 0.12)
        }
        // A band may be skipped (no grey among its clusters) at a fixed price; the path then bridges it.
        let skipCost = 2.5
        // Nodes: (layer, candidate); best cost to reach each, and its predecessor (nil = origin).
        struct Node { var layer: Int; var cand: Int }
        var best: [[(cost: Double, prev: Node?)]] = layers.map { $0.map { _ in (Double.infinity, nil) } }
        func point(_ n: Node?) -> FrameStats.Neutral { n.map { layers[$0.layer][$0.cand] } ?? origin }
        for k in layers.indices {
            for j in layers[k].indices {
                let c = layers[k][j]
                let own = -log(c.weight + 0.02) + (anchored ? prior(c) : 0)
                var options: [(Node?, Double)] = [(nil, skipCost * Double(k))]
                for kk in 0..<k { for jj in layers[kk].indices where best[kk][jj].cost.isFinite {
                    options.append((Node(layer: kk, cand: jj), best[kk][jj].cost + skipCost * Double(k - kk - 1)))
                } }
                for (prev, base) in options {
                    let p = point(prev)
                    let sl = slope(p, c)
                    var v = base + own + (prev == nil && !anchored ? 0 : simd_length_squared(sl) / (slopeScale * slopeScale))
                    if let prev {
                        let pp = point(best[prev.layer][prev.cand].prev)
                        v += simd_length_squared(sl - slope(pp, p)) / (bendScale * bendScale)
                    }
                    if v < best[k][j].cost { best[k][j] = (v, prev) }
                }
            }
        }
        var end: Node?, endCost = Double.infinity
        for k in layers.indices { for j in layers[k].indices {
            let v = best[k][j].cost + skipCost * Double(layers.count - 1 - k)
            if v < endCost { endCost = v; end = Node(layer: k, cand: j) }
        } }
        var path: [FrameStats.Neutral] = []
        var n = end
        while let node = n { path.append(layers[node.layer][node.cand]); n = best[node.layer][node.cand].prev }
        return path.reversed()
    }

    /// The roll's neutral path: each frame's path, pooled per band (weighted medians), smoothed, starting at the
    /// base and kept monotonic in every channel.
    public static func rollPath(stats: [FrameStats], anchored: Bool = true) -> [SIMD3<Double>] {
        let paths = stats.map { framePath($0, anchored: anchored) }
        let bands = Set(paths.flatMap { $0.map(\.band) }).sorted()
        var pts: [SIMD3<Double>] = anchored ? [.zero] : []
        for b in bands {
            let ps = paths.compactMap { $0.first { $0.band == b } }
            guard !ps.isEmpty else { continue }
            let w = ps.map { $0.weight + 0.02 }
            pts.append(SIMD3(Statistics.weightedMedian(ps.map(\.g), weights: w),
                             Statistics.weightedMedian(ps.map(\.dr), weights: w),
                             Statistics.weightedMedian(ps.map(\.db), weights: w)))
        }
        pts.sort { $0.x < $1.x }
        if !anchored {
            // Below the first measured point the path continues along its first segment (gently).
            guard let f = pts.first else { return [] }
            var lead = SIMD3<Double>(min(0, f.x - 0.5), f.y, f.z)
            if pts.count >= 2 {
                let n = pts[1], dg = max(n.x - f.x, 0.05)
                let sr = min(max((n.y - f.y) / dg, -0.3), 0.3), sb = min(max((n.z - f.z) / dg, -0.3), 0.3)
                lead.y = f.y - sr * (f.x - lead.x); lead.z = f.z - sb * (f.x - lead.x)
            }
            pts.insert(lead, at: 0)
        }
        // Light smoothing of the chroma between measured points (the base point does not pull on them).
        if pts.count >= 4 {
            var sm = pts
            for k in 2..<(pts.count - 1) {
                sm[k].y = 0.25 * pts[k - 1].y + 0.5 * pts[k].y + 0.25 * pts[k + 1].y
                sm[k].z = 0.25 * pts[k - 1].z + 0.5 * pts[k].z + 0.25 * pts[k + 1].z
            }
            pts = sm
        }
        // Monotonic: each channel's density must rise with green's (slope of g + chroma ≥ 0.3).
        var out: [SIMD3<Double>] = [pts[0]]
        for p in pts.dropFirst() {
            guard let q = out.last, p.x - q.x > 0.02 else { continue }
            var v = p
            let dg = p.x - q.x
            v.y = max(v.y, q.y - 0.7 * dg)
            v.z = max(v.z, q.z - 0.7 * dg)
            out.append(v)
        }
        // Beyond the measured tones the path continues gently (the last slope, limited), so a few extreme pixels
        // can't swing the brightest highlights' colour.
        var path = Array(out.prefix(FilmCalibration.maxPathPoints - 1))
        if path.count >= 2 {
            let a = path[path.count - 2], b = path[path.count - 1]
            let dg = max(b.x - a.x, 0.05)
            let sr = min(max((b.y - a.y) / dg, -0.3), 0.3), sb = min(max((b.z - a.z) / dg, -0.3), 0.3)
            path.append(SIMD3(b.x + 2, b.y + 2 * sr, b.z + 2 * sb))
        }
        return path
    }

    /// Scene values the bright tones (90th percentile) and the centre-weighted average print at. Measured on
    /// real scenes as their cameras exposed them, the 90th percentile sits at +1.15 stops over middle grey within
    /// about ±0.5 stop; the average varies three times more.
    public static let brightSceneValue = 0.184 * pow(2, 1.15)
    public static let averageSceneValue = 0.12

    /// Green-equivalent density that maps to scene 1.0 for this frame (so its bright tones print at
    /// `brightSceneValue`).
    public static func frameReference(_ s: FrameStats, _ cal: FilmCalibration, filmGamma: Double, monochromeWeights: SIMD3<Double>? = nil) -> Double {
        func level(_ d: SIMD3<Double>) -> Double {
            let e = cal.equivalentDensity(d)
            return monochromeWeights.map { simd_dot(e, $0) } ?? (e.x + e.y + e.z) / 3
        }
        if let b = s.bright { return level(b) - filmGamma * log10(brightSceneValue) }
        return level(s.average) - filmGamma * log10(averageSceneValue)
    }

    public static func rollReferenceDensity(stats: [FrameStats], _ cal: FilmCalibration, filmGamma: Double) -> Double? {
        let v = stats.map { frameReference($0, cal, filmGamma: filmGamma) }
        return v.isEmpty ? nil : Statistics.median(v)
    }

    /// Per-frame exposure (EV) that prints this frame's average at the target, relative to the roll reference.
    public static func autoExposure(stats s: FrameStats, calibration: FilmCalibration, referenceDensity: Double, filmGamma: Double,
                                    monochromeWeights: SIMD3<Double>? = nil) -> Double {
        let ref = frameReference(s, calibration, filmGamma: filmGamma, monochromeWeights: monochromeWeights)
        return min(max(-(ref - referenceDensity) / filmGamma * log2(10.0), -4), 4)
    }
}
