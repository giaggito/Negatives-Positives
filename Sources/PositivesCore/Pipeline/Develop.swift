import Foundation
import simd

/*
 THE FIXED PIPELINE ORDER
 ========================
 Every photograph goes through the same chain, in this order (the GPU kernels follow it exactly; the
 CPU reference below is the readable version):

   1. Decode / linearise     RAF: LibRaw Markesteijn 3-pass, highlights rebuilt, camera crop.
                             Others: ICC profile -> linear Rec.2020 float (ColorSync).
      Layers                 other photos composited in scene light (LayerMath), so everything below acts
                             on the double exposure as one picture.
   2. Geometry               flips, quarter turns, straighten, crop — one Lanczos-3 resampling (none when
                             the crop is pixel-aligned). Everything after works on the final pixel grid.
   3. White balance          RAF: diagonal in camera RGB (real raw WB) then camera matrix -> Rec.2020.
                             Others: un-render through S⁻¹, then Bradford adaptation in linear light.
   4. Dehaze                 haze model I = J·t + A·(1 − t) inverted, scene-linear.
   5. Exposure               multiply by 2^(EV + baseline).
   6. Local tone             shadows / highlights from an edge-aware base layer, clarity (edge-aware
                             mid-frequency detail), texture (fine detail) — all in log luminance, applied
                             as a gain to R, G and B together (hue-safe).
   7. Bloom                  scene light above a threshold, spread at two scales (lens / diffusion glow).
   8. Tone profile or film   Digital: scene -> display S-curve per channel (RAF) or the display shoulder.
                             Film look: halation (light reflected back into the film), grain as fluctuations
                             of the film's exposure, print filtration, the digital rendering, then the
                             film's colour table (in sRGB). Physical film (CineStill): spectral exposure,
                             development with grain in density, scan.
                             Then contrast, whites, blacks and the master curve in perceptual units, hue
                             restored (to the film's hue when there is a film).
   9. R, G, B curves         per channel — these shift colour on purpose.
  10. Colour                 OKLab: vibrance, saturation, Color Chrome effects, colour mixer (8 ranges),
                             targeted colours, colour grading (shadows / midtones / highlights / global).
  11. Vignette               in display light.
  12. Digital grain          (no film chosen) on the finished picture, in density.
  13. Output                 display-linear Rec.2020 float; resized and sharpened for the medium
                             (OutputFinish: the picture is sharpened, the grain laid back on untouched),
                             quantised only by the exporter.

 Everything that works on detail (dehaze, local tone, clarity, texture, bloom, film softness, halation) runs
 before the grain exists and reads maps of the clean picture, so it never sharpens or softens the grain;
 after the film come only per-pixel "printing" adjustments (tone, colour, vignette). Masks modulate the
 parameters of stages 3–10 per pixel.
 */

/// Everything the per-pixel step needs, resolved from an `EditState` and a `SourceImage`.
public struct DevelopParameters: Equatable, Sendable {
    /// Native -> scene-linear Rec.2020 (white balance included).
    public var inputMatrix: simd_float3x3
    /// Display-referred source: apply S⁻¹ per channel before the input matrix, S as the profile.
    public var unrender: Bool
    /// 2^(EV + baseline) and its log2.
    public var exposureGain: Float
    public var exposureStops: Float

    public var shadows: Float = 0, highlights: Float = 0
    public var clarity: Float = 0, texture: Float = 0
    /// −1…1, and the atmospheric light (scene-linear, before exposure).
    public var dehaze: Float = 0
    public var airlight = SIMD3<Float>(repeating: 1)

    /// 0 = linear (none), 1 = print curve, 2 = display shoulder.
    public var profileKind: Int
    public var print: PrintCurve.Resolved?
    public var contrastSlope: Float = 1
    public var whites: Float = 0, blacks: Float = 0
    /// Recipe: highlight / shadow tone (−2…+4) and dynamic-range highlight compression (0 = DR100).
    public var highlightTone: Float = 0, shadowTone: Float = 0
    public var drCompression: Float = 0

    /// Tone curves baked to a table (master, R, G, B) in perceptual units; nil when all are straight.
    public var curveLUT: [SIMD4<Float>]?
    public var masterCurve = false, rgbCurves = false

    public var saturation: Float = 0, vibrance: Float = 0
    /// Fujifilm-style Color Chrome effects, 0…1: deeper tones in saturated colours / in blues.
    public var colorChrome: Float = 0, colorChromeBlue: Float = 0
    /// Print filtration (warmth / tint) as gains on scene light before the film.
    public var filmBalance = SIMD3<Float>(repeating: 1)
    /// Colour mixer per range: (hue shift radians, saturation, luminance); nil when neutral.
    public var mixer: [SIMD3<Float>]?
    public var targets: [ColorMath.Target] = []
    public var grading: ColorMath.Grading?
    /// ≥ 0: show which pixels belong to targeted colour `overlayTarget` (everything else dimmed to grey).
    public var overlayTarget = -1

    /// Film simulation (nil = digital rendering) and its blend with the digital rendering (0…1).
    public var film: PreparedFilm?
    public var filmIntensity: Float = 1
    /// Film look (colour table) instead of the physical simulation.
    public var look: LookRender?
    /// Halation strength per layer and its first radius (µm on the film).
    public var halation = SIMD3<Float>.zero
    public var halationRadius: Double = 65
    /// Bloom: tint × amount, threshold (linear scene light), radius (fraction of the long side).
    public var bloomTint = SIMD3<Float>.zero
    public var bloomThreshold: Float = 0.72
    public var bloomRadius: Double = 0.02
    /// Grain (nil = none).
    public var grain: GrainRender?
    /// Emulsion light scatter (0…1) and its radius in µm.
    public var softness: Float = 0
    /// Masks (in order) and their resolved adjustments; at most `LocalAdjustment.maximumCount`.
    public var masks: [LocalAdjustment] = []
    /// Double-exposure layers (composited by the engine before development).
    public var layers: [PhotoLayer] = []
    /// Every mask part of the masks and of the layers' masks.
    public var allMaskParts: [MaskComponent] { masks.flatMap(\.components) + layers.flatMap(\.mask.components) }
    public var locals: [LocalRender] = []
    public var hasLocals: Bool { !locals.isEmpty }
    /// Mask shown in red (index into `masks`), −1 = none.
    public var maskOverlay = -1
    /// Coarse maps needed by global or local controls.
    public var needsMidMap: Bool { clarity != 0 || locals.contains { $0.clarityGain != 0 } }
    public var needsDarkMap: Bool { dehaze != 0 || locals.contains { $0.dehaze != 0 } }
    public var needsLocalShape: Bool { locals.contains { $0.hasShape } }
    /// Vignette (amount −1…1, midpoint, feather, roundness), highlights 0…1.
    public var vignette = SIMD4<Float>.zero
    public var vignetteHighlights: Float = 0
    public var hasBloom: Bool { bloomTint != .zero }
    public var hasHalation: Bool { (film != nil || look != nil) && halation != .zero }
    public var hasFilm: Bool { film != nil || look != nil }

    /// Which parts actually do something (lets neutral stages be skipped exactly).
    public var needsLocal: Bool { shadows != 0 || highlights != 0 || clarity != 0 || texture != 0 || locals.contains { $0.hasTone } }
    public var needsToneStage: Bool {
        needsLocal || profileKind != 0 || contrastSlope != 1 || whites != 0 || blacks != 0 || exposureGain != 1 || dehaze != 0
            || masterCurve || rgbCurves || hasFilm || hasBloom || grain != nil || vignette.x != 0 || softness > 0 || hasLocals
            || highlightTone != 0 || shadowTone != 0 || drCompression != 0
    }
    /// A display-referred file with nothing changed: the output is the input, bit for bit.
    public var isIdentity: Bool {
        unrender && inputMatrix == matrix_identity_float3x3 && !needsLocal && contrastSlope == 1 && whites == 0 && blacks == 0
            && exposureGain == 1 && dehaze == 0 && !needsColour && !masterCurve && !rgbCurves && !hasFilm && !hasBloom
            && grain == nil && vignette.x == 0 && softness == 0 && !hasLocals && highlightTone == 0 && shadowTone == 0 && drCompression == 0
    }
    public var needsColour: Bool {
        saturation != 0 || vibrance != 0 || colorChrome != 0 || colorChromeBlue != 0 || locals.contains { $0.hasColour } || mixer != nil || !targets.isEmpty || grading != nil || overlayTarget >= 0
    }

    public static func resolve(_ edit: EditState, source: SourceImage, overlayTarget: Int? = nil, overlayMask: Int? = nil) -> DevelopParameters {
        let e = edit.effective
        let profile = e.profile ?? source.defaultProfile
        let ev = e.light.exposure + (profile == .original ? 0 : source.baselineExposure)
        var p = DevelopParameters(
            inputMatrix: simd_float3x3(source.inputMatrix(whiteBalance: e.whiteBalance)),
            unrender: source.kind == .display,
            exposureGain: Float(pow(2, ev)),
            exposureStops: Float(ev),
            profileKind: profile == .original ? 2 : (profile == .linear ? 0 : 1),
            print: ToneMath.printCurve(for: profile)?.resolved)
        p.shadows = Float(e.light.shadows / 100)
        p.highlights = Float(e.light.highlights / 100)
        p.contrastSlope = Float(pow(2, 0.9 * e.light.contrast / 100))
        p.whites = Float(e.light.whites / 100)
        p.blacks = Float(e.light.blacks / 100)
        p.clarity = Float((e.presence.clarity + 8 * e.recipe.clarity) / 100)
        p.texture = Float(e.presence.texture / 100)
        p.dehaze = Float(e.presence.dehaze / 100)
        p.saturation = Float((e.color.saturation + 8 * e.recipe.color) / 100)
        p.vibrance = Float(e.color.vibrance / 100)
        if !e.curves.isNeutral {
            p.curveLUT = CurveMath.bake(e.curves)
            p.masterCurve = !e.curves.masterIsIdentity
            p.rgbCurves = !e.curves.rgbIsIdentity
        }
        if !e.mixer.isNeutral {
            var m: [SIMD3<Float>] = []
            for i in 0..<8 {
                let h: Double = e.mixer.hue[i] / 100 * 30 * Double.pi / 180
                let sat: Double = e.mixer.saturation[i] / 100
                let lum: Double = e.mixer.luminance[i] / 100
                m.append(SIMD3<Float>(Float(h), Float(sat), Float(lum)))
            }
            p.mixer = m
        }
        p.targets = e.targeted.prefix(TargetedColor.maximumCount).map(ColorMath.Target.init)
        if !e.grading.isNeutral { p.grading = ColorMath.Grading(e.grading) }
        // Film, grain, light effects, vignette.
        let look = e.film.isActive ? FilmLooks.shared.look(e.film.stock) : nil
        if let look {
            p.filmIntensity = Float(e.film.intensity / 100)
            p.halation = SIMD3<Float>(look.halation * e.film.halation / 100)
            p.halationRadius = look.halationRadius
            if let stock = look.spectralStock {
                var fs = e.film
                fs.stock = stock
                p.film = PreparedFilm.prepare(fs)
                if p.film == nil { p.filmIntensity = 1; p.halation = .zero }
            } else if let t = FilmLooks.shared.table(look, variant: e.film.variant) {
                p.look = LookRender(key: look.variants[e.film.variant] ?? look.variants[0]!, table: t,
                                    grainCurve: look.kind == .slide || look.kind == .instant ? 1 : (look.isBlackAndWhite ? 2 : 0))
            } else {
                p.halation = .zero
            }
            if e.film.paper == nil {
                p.filmBalance = FilmSettings.balance(warmth: e.film.warmth, tint: e.film.tint)
            }
        }
        if e.grain.isActive {
            let preset = GrainPreset.all.first { $0.id == e.grain.preset }
            let character = preset?.character ?? (p.hasFilm ? look?.grain : nil) ?? GrainPreset.all[1].character
            p.grain = GrainRender(settings: e.grain, character: character, monochrome: look?.isBlackAndWhite ?? false)
            if !p.hasFilm { p.grain?.visibilityScale = 8 }
        }
        if p.hasFilm || p.grain != nil { p.softness = Float(e.grain.softness / 100) }
        // Recipe: tone, dynamic range, white-balance shift; black & white lens filter.
        p.highlightTone = Float(e.recipe.highlight)
        p.shadowTone = Float(e.recipe.shadow)
        p.drCompression = e.recipe.highlightCompression
        var pre = simd_float3x3(diagonal: SIMD3<Float>(e.recipe.shiftGains))
        if let look, look.isBlackAndWhite, e.film.bwFilter != .none {
            pre = e.film.bwFilter.greyMatrix(weights: p.look?.channelWeights ?? ToneMath.luminance) * pre
        }
        if pre != matrix_identity_float3x3 { p.inputMatrix = pre * p.inputMatrix }
        // Masks and layers.
        p.layers = e.layers
        p.masks = Array(e.masks.prefix(LocalAdjustment.maximumCount))
        if !p.masks.isEmpty {
            let wb = e.whiteBalance ?? source.asShotWhiteBalance
            let global = source.inputMatrix(whiteBalance: e.whiteBalance)
            p.locals = p.masks.map {
                LocalRender.resolve($0.settings, globalWhiteBalance: wb, withWhiteBalance: { source.inputMatrix(whiteBalance: $0) }, globalMatrix: global)
            }
        }
        if let o = overlayMask, edit.masks.indices.contains(o) {
            p.maskOverlay = p.masks.firstIndex { $0.id == edit.masks[o].id } ?? -1
        }
        p.colorChrome = Float(e.color.colorChrome / 100)
        p.colorChromeBlue = Float(e.color.colorChromeBlue / 100)
        let b = e.effects.bloom
        if b.amount > 0 {
            let w = b.warmth / 100
            let tint = SIMD3<Double>(1 + 0.25 * w, 1, 1 - 0.35 * w)
            p.bloomTint = SIMD3<Float>(tint * b.amount / 100 * 0.6)
            p.bloomThreshold = Float(0.184 * pow(2, b.threshold))
            p.bloomRadius = 0.004 + 0.06 * b.radius / 100
        }
        let v = e.effects.vignette
        if v.amount != 0 {
            let mid = Float(v.midpoint / 100) * 0.9
            p.vignette = SIMD4(Float(v.amount / 100), mid, Float(0.05 + 0.95 * v.feather / 100) * (1 - mid) + 0.02, Float(v.roundness / 100))
            p.vignetteHighlights = Float(v.highlights / 100)
        }
        if let o = overlayTarget {
            // The overlay refers to the full list (switched-off ranges included): find it among the active ones.
            let id = edit.targeted.indices.contains(o) ? edit.targeted[o].id : nil
            p.overlayTarget = e.targeted.firstIndex { $0.id == id } ?? -1
        }
        return p
    }

    /// Clarity / texture gains (positive boosts detail, negative smooths it).
    public var clarityGain: Float { clarity >= 0 ? 0.9 * clarity : 0.85 * clarity }
    public var textureGain: Float { texture >= 0 ? 0.8 * texture : 0.8 * texture }
}

/// A film look's colour table, resolved for rendering.
public struct LookRender: Equatable, Sendable {
    public let key: String
    public let table: FilmLooks.Table
    /// Characteristic curve the grain follows: 0 colour negative, 1 slide / instant, 2 black & white negative.
    public let grainCurve: Int
    public static func == (a: LookRender, b: LookRender) -> Bool { a.key == b.key && a.grainCurve == b.grainCurve }
    public init(key: String, table: FilmLooks.Table, grainCurve: Int) { self.key = key; self.table = table; self.grainCurve = grainCurve }

    /// Display-linear Rec.2020 -> the film's colour (display-linear Rec.2020): the table works on sRGB codes,
    /// so colours outside sRGB are first brought inside by desaturating towards their luminance.
    public func apply(_ c: SIMD3<Float>) -> SIMD3<Float> {
        var l = ToneMath.rec2020ToSRGB * c
        let y = ToneMath.lum(c)
        let lo = l.min()
        if lo < 0 {
            let t = y > 0 ? min(1, y / (y - lo)) : 0
            l = SIMD3(repeating: max(y, 0)) + (l - SIMD3(repeating: y)) * t
        }
        l = simd_clamp(l, .zero, .one)
        let e = SIMD3<Float>(ToneMath.srgbEncode(l.x), ToneMath.srgbEncode(l.y), ToneMath.srgbEncode(l.z))
        let o = table.lookup(e)
        let lin = SIMD3<Float>(ToneMath.srgbDecode(o.x), ToneMath.srgbDecode(o.y), ToneMath.srgbDecode(o.z))
        return ToneMath.srgbToRec2020 * lin
    }

    /// How much each input channel adds to the look's brightness around middle grey (sums to 1) — for a
    /// black & white table, the film's own colour sensitivity.
    public var channelWeights: SIMD3<Float> {
        let g: Float = 0.18, d: Float = 0.03
        var w = SIMD3<Float>.zero
        for i in 0..<3 {
            var a = SIMD3<Float>(repeating: g), b = a
            a[i] += d; b[i] -= d
            w[i] = max(0, ToneMath.lum(apply(ToneMath.lookInput(a))) - ToneMath.lum(apply(ToneMath.lookInput(b))))
        }
        let sum = w.sum()
        return sum > 1e-6 ? w / sum : ToneMath.luminance
    }
}

/// Grain parameters resolved from the settings and the stock's character.
public struct GrainRender: Equatable, Sendable {
    public var character: GrainCharacter
    /// Visibility multiplier (amount), size multiplier, roughness 0…1, colour 0…1.
    public var amount: Double
    public var size: Double
    public var roughness: Double
    public var colour: Double
    public var frameLongSideMM: Double
    public var seed: UInt32
    /// Digital grain (no film) is laid on the finished picture, where it shows less: scaled to match film.
    public var visibilityScale: Double = 1

    init(settings g: GrainSettings, character c: GrainCharacter, monochrome: Bool) {
        character = c
        amount = g.amount / 100
        size = g.size / 100
        roughness = (g.roughness.map { $0 / 100 }) ?? c.roughness
        colour = monochrome ? 0 : ((g.colour.map { $0 / 100 }) ?? c.colour)
        frameLongSideMM = g.format.longSideMM
        seed = g.seed
    }

    /// Calibration of on-screen grain against datasheet granularity (see `constants`).
    public static let visibility = 0.5
    /// Extra calibration for film looks, whose grain goes through a typical film curve and the look's table.
    public static let lookVisibility = 1.0


    /// How grain is drawn at a render pixel size of `a` µm on the film.
    public struct Field: Equatable, Sendable {
        /// Boolean model (grains visible) or a Gaussian fallback (grains much smaller than a pixel).
        public var boolean: Bool
        /// Median grain radius, σ of its logarithm, and the blur it is seen through (µm).
        public var radius: Double, sigmaLn: Double, filter: Double
        /// Grain intensities of the sparse / dense populations (per µm²), Poisson cell size and reach (µm).
        public var lambdaSparse: Double, lambdaDense: Double, cell: Double, reach: Double, maxRadius: Double
        /// Density variance per unit density per render pixel (see `variance`).
        public var k: Float
    }

    /// Coverage of the sparse / dense grain populations (fraction of the film area covered by grains).
    public static let sparseCoverage = 0.3, denseCoverage = 0.72

    /// Grain field for a render pixel of `a` µm on the film.
    ///
    /// Strength (shot noise, calibrated on the datasheet): grains of radius ρ and peak density δ give a
    /// density variance of D·δ·Ψ/2 in a pixel of side a, Ψ = J(a, √2ρ)²,
    ///     J(a, s) = (2s²/a²)(e^(−a²/2s²) − 1) + (s√(2π)/a)·erf(a/(s√2)),
    /// with δ from the granularity G (RMS × 1000 at D = 1 through a 48 µm aperture): G² = 2πρ²δ/A₄₈.
    /// Size scales radius and granularity together (bigger grain is also more visible).
    public func field(renderPixelMicrons a: Double) -> Field {
        let r = character.coarseRadius * size
        let sl = 0.15 + 0.55 * roughness
        // The pixel's own extent and the scan's optics (≈ 2.5 µm) soften every grain a little.
        let filter = ((0.45 * a) * (0.45 * a) + 2.5 * 2.5).squareRoot()
        let er2 = r * r * exp(2 * sl * sl)
        let ls = -log(1 - Self.sparseCoverage) / (.pi * er2), ld = -log(1 - Self.denseCoverage) / (.pi * er2)
        // Cells hold ~1.5 grains on average; the rare grains beyond 1.5 σ are capped there.
        let cell = (1.5 / ld).squareRoot()
        let rmax = r * exp(1.5 * sl)
        let g = character.granularity / 1000 * amount * size.squareRoot() * visibilityScale.squareRoot()
        let a48 = Double.pi * 24 * 24
        let delta = g * g * a48 / (2 * .pi * r * r)
        func j(_ a: Double, _ s: Double) -> Double {
            2 * s * s / (a * a) * (exp(-a * a / (2 * s * s)) - 1) + s * (2 * Double.pi).squareRoot() / a * erf(a / (s * 2.0.squareRoot()))
        }
        let psi = pow(j(a, 2.0.squareRoot() * r), 2)
        return Field(boolean: r / a >= 0.6, radius: r, sigmaLn: sl, filter: filter, lambdaSparse: ls, lambdaDense: ld,
                     cell: cell, reach: rmax + 2.5 * filter, maxRadius: rmax, k: Float(delta * psi / 2 * Self.visibility))
    }
}

/// Neighbourhood values the per-pixel step reads at a pixel (from the coarse maps / blur pass).
public struct LocalValues: Sendable {
    /// Edge-aware large-scale base, log2(Y / 0.18) before exposure.
    public var base: Float
    /// Edge-aware mid-scale base (clarity), same units.
    public var mid: Float
    /// Fine Gaussian (texture), same units.
    public var fine: Float
    /// Smoothed, normalised dark channel (dehaze).
    public var dark: Float
    /// Weight of each mask at the pixel (see `MaskMath.weight`).
    public var masks: [Float]
    public init(base: Float, mid: Float, fine: Float, dark: Float, masks: [Float] = []) {
        self.base = base; self.mid = mid; self.fine = fine; self.dark = dark; self.masks = masks
    }
}

public enum Develop {
    /// The colour luminance and colour masks look at (`mask_eval`): the pixel after white balance and
    /// exposure, through the default tone profile with its hue kept, in OKLab.
    public static func maskLab(_ native: SIMD3<Float>, _ p: DevelopParameters) -> SIMD3<Float> {
        var c = p.unrender ? ToneMath.shoulderInverse(native) : native
        c = p.inputMatrix * c * p.exposureGain
        func profile(_ y: Float) -> Float {
            switch p.profileKind {
            case 1: return ToneMath.printCurve(y, p.print!)
            case 2: return y < 0 ? y : ToneMath.shoulder(y)
            default: return y
            }
        }
        var s = SIMD3(profile(c.x), profile(c.y), profile(c.z))
        if s != c {
            var ls = ToneMath.oklab(s)
            let a = ToneMath.oklab(c)
            let ca = simd_length(SIMD2(a.y, a.z))
            if ca > 1e-5 { let cc = simd_length(SIMD2(ls.y, ls.z)); ls.y = a.y / ca * cc; ls.z = a.z / ca * cc }
            s = ToneMath.fromOklab(ls)
        }
        return ToneMath.oklab(s)
    }

    /// CPU reference of the per-pixel step (the GPU kernel `develop` is a transcription of this).
    public static func pixel(_ native: SIMD3<Float>, _ p: DevelopParameters, local: LocalValues) -> SIMD3<Float> {
        if p.isIdentity { return native }
        // 3. White balance (+ un-render for display-referred files)
        var c = p.unrender ? ToneMath.shoulderInverse(native) : native
        c = p.inputMatrix * c
        guard p.needsToneStage || p.needsColour else { return c }

        // Masks: their weights here, and the sums of their additive controls.
        var ev: Float = 0, dehaze = p.dehaze, shadows = p.shadows, highlights = p.highlights, clarity = p.clarityGain
        var contrastShift: Float = 0, saturation: Float = 0, cast = SIMD2<Float>.zero
        let mw = p.locals.indices.map { $0 < local.masks.count ? local.masks[$0] : 0 }
        for (i, l) in p.locals.enumerated() where mw[i] > 0 {
            let w = mw[i]
            if let m = l.whiteBalance { c += (m * c - c) * w }
            ev += w * l.exposureStops; dehaze += w * l.dehaze
            shadows += w * l.shadows; highlights += w * l.highlights; clarity += w * l.clarityGain
            contrastShift += w * l.contrast; saturation += w * l.saturation; cast += w * l.cast
        }

        // 4. Dehaze, scene-linear, before exposure
        if dehaze > 0 {
            let t = max(1 - 0.95 * dehaze * local.dark, 0.15)
            c = (c - p.airlight) / t + p.airlight
        } else if dehaze < 0 {
            let t = 1 + 0.55 * dehaze
            c = c * t + p.airlight * (1 - t)
        }

        // 5. Exposure
        c *= p.exposureGain * exp2(ev)
        let stops = p.exposureStops + ev

        // 6. Local tone, in stops relative to middle grey
        if p.needsLocal {
            let y = max(ToneMath.lum(c), 1e-10)
            let l = log2(y / ToneMath.middleGrey)
            let b = local.base + stops
            var dl = ToneMath.shadowsHighlights(base: b, shadows: shadows, highlights: highlights)
            if clarity != 0 {
                dl += ToneMath.detailBoost(l - (local.mid + stops), gain: clarity) * ToneMath.clarityWeight(base: b)
            }
            if p.texture != 0 {
                dl += ToneMath.detailBoost(l - (local.fine + stops), gain: p.textureGain)
            }
            c *= exp2(dl)
        }

        // 7. Tone profile (or film), contrast / whites / blacks and the master curve, per channel; hue restored
        // after. With a film, the film's own colour is the reference (its hue shifts are the look).
        if p.drCompression != 0 { c *= ToneMath.dynamicRange(ToneMath.lum(c), p.drCompression) }
        var scene = c
        var d = c
        let shape = p.contrastSlope != 1 || p.whites != 0 || p.blacks != 0 || p.masterCurve || p.needsLocalShape
            || p.highlightTone != 0 || p.shadowTone != 0
        let contrastK = p.contrastSlope * exp2(0.9 * contrastShift)
        func profile(_ y: Float) -> Float {
            switch p.profileKind {
            case 1: return ToneMath.printCurve(y, p.print!)
            case 2: return y < 0 ? y : ToneMath.shoulder(y)
            default: return y
            }
        }
        func shapeChannel(_ y: Float) -> Float {
            guard shape else { return y }
            var q = ToneMath.toPerceptual(y)
            q = ToneMath.contrast(q, k: contrastK)
            q = ToneMath.whitesBlacks(q, whites: p.whites, blacks: p.blacks)
            q = ToneMath.recipeTone(q, highlight: p.highlightTone, shadow: p.shadowTone)
            if p.masterCurve { q = CurveMath.lookup(p.curveLUT!, q, channel: 0) }
            for (i, l) in p.locals.enumerated() where mw[i] > 0 {
                if let t = l.curve { q += (CurveMath.lookup1(t, q) - q) * mw[i] }
            }
            return ToneMath.fromPerceptual(q)
        }
        func digital(_ c: SIMD3<Float>) -> SIMD3<Float> {
            var s = SIMD3(profile(c.x), profile(c.y), profile(c.z))
            if s != c {
                var ls = ToneMath.oklab(s)
                let a = ToneMath.oklab(c)
                let ca = simd_length(SIMD2(a.y, a.z))
                if ca > 1e-5 { let cc = simd_length(SIMD2(ls.y, ls.z)); ls.y = a.y / ca * cc; ls.z = a.z / ca * cc }
                s = ToneMath.fromOklab(ls)
            }
            return s
        }
        if p.hasFilm {
            let cb = c * p.filmBalance
            var f: SIMD3<Float>
            let s: SIMD3<Float>
            if let look = p.look {
                s = digital(cb)
                f = look.apply(ToneMath.lookInput(s))
            } else {
                s = digital(c)
                f = p.film!.renderPixel(cb)
            }
            if p.filmIntensity < 1 { f = s + (f - s) * p.filmIntensity }
            scene = f
            d = SIMD3(shapeChannel(f.x), shapeChannel(f.y), shapeChannel(f.z))
        } else {
            for k in 0..<3 { d[k] = shapeChannel(profile(d[k])) }
        }
        // Hue restore in OKLab: keep the toned lightness and chroma with the scene hue.
        var lab: SIMD3<Float>?
        if d != scene {
            var l = ToneMath.oklab(d)
            let a = ToneMath.oklab(scene)
            let ca = simd_length(SIMD2(a.y, a.z))
            if ca > 1e-5 {
                let cc = simd_length(SIMD2(l.y, l.z))
                l.y = a.y / ca * cc; l.z = a.z / ca * cc
            }
            lab = l
        }
        // 7c. Per-channel curves (these deliberately shift colour, like colour filtration).
        if p.rgbCurves {
            if let l = lab { d = ToneMath.fromOklab(l); lab = nil }
            for k in 0..<3 {
                d[k] = ToneMath.fromPerceptual(CurveMath.lookup(p.curveLUT!, ToneMath.toPerceptual(d[k]), channel: k + 1))
            }
        }
        // 8. Colour, in OKLab: vibrance / saturation, mixer, targeted colours, grading.
        var overlay: Float = -1
        if p.needsColour {
            var l = lab ?? ToneMath.oklab(d)
            if p.saturation != 0 || p.vibrance != 0 {
                let ch = simd_length(SIMD2(l.y, l.z))
                let f = ToneMath.chromaGain(chroma: ch, hue: atan2(l.z, l.y), saturation: p.saturation, vibrance: p.vibrance)
                l.y *= f; l.z *= f
            }
            if saturation != 0 || cast != .zero {
                let f = max(0, 1 + saturation)
                l.y = l.y * f + cast.x; l.z = l.z * f + cast.y
            }
            if p.colorChrome != 0 || p.colorChromeBlue != 0 { l = ColorMath.colorChrome(l, p.colorChrome, p.colorChromeBlue) }
            if let m = p.mixer { l = ColorMath.applyMixer(l, m) }
            if p.overlayTarget >= 0 { overlay = ColorMath.targetWeight(l, p.targets[p.overlayTarget]) }
            if !p.targets.isEmpty { l = ColorMath.applyTargets(l, p.targets) }
            if let g = p.grading { l = ColorMath.applyGrading(l, g) }
            lab = l
        }
        if let l = lab { d = ToneMath.fromOklab(l) }
        // Selection overlay: the picked range in colour, everything else a dim grey.
        if overlay >= 0 {
            let grey = SIMD3<Float>(repeating: max(0, ToneMath.lum(d)) * 0.3)
            d = grey + (d - grey) * overlay
        }
        if p.maskOverlay >= 0, p.maskOverlay < mw.count {
            d += (SIMD3<Float>(0.75, 0.02, 0.02) - d) * (0.55 * mw[p.maskOverlay])
        }
        return d
    }
}
