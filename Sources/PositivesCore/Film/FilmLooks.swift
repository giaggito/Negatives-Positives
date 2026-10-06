import Compression
import Foundation
import simd

/// The film looks Positives offers.
///
/// Most are colour look-up tables made by photographers to match how each stock looks when scanned —
/// the RawTherapee Film Simulation Collection (Pat David, Pavlov Dmitry, Michael Ezra; CC BY-SA 4.0) and, for
/// Kodak Gold, UltraMax and ColorPlus, t3mujinpack (João Almeida; MIT). CineStill stocks, whose look comes
/// from tungsten balance and halation rather than from a lab's colour, are simulated physically from the
/// cinema stocks' spectral data (spektrafilm, Andrea Volpato; CC BY-SA 4.0).
///
/// Film names are trademarks of their owners, used only to say which film a look approximates; Positives is
/// not affiliated with or endorsed by them.
public struct FilmLook: Identifiable, Sendable {
    public enum Kind: String, Sendable { case colorNegative, slide, blackAndWhite, instant, cinema }
    public enum Source: String, Sendable { case rawTherapee, t3mujinpack, spektrafilm }

    public let id: String
    public let name: String
    public let kind: Kind
    /// Lab variants −1…+2 → source table (file name without extension). 0 is the standard look.
    public let variants: [Int: String]
    /// Simulated physically from this spectral stock instead of a look-up table.
    public let spectralStock: String?
    public let grain: GrainCharacter
    /// Halation strength per channel (R, G, B) and its first radius in µm on the film.
    public let halation: SIMD3<Double>
    public let halationRadius: Double
    public let note: String
    public let source: Source

    public var isBlackAndWhite: Bool { kind == .blackAndWhite }
    public var isSpectral: Bool { spectralStock != nil }
    public var availableVariants: [Int] { variants.keys.sorted() }

    /// The name without the maker (for small labels).
    public var shortName: String {
        for brand in ["Kodak ", "Fujifilm ", "Ilford ", "Agfa ", "Polaroid "] where name.hasPrefix(brand) && brand != "Polaroid " {
            return String(name.dropFirst(brand.count))
        }
        return name
    }

    /// Where the look comes from (shown under the film's options).
    public var creditLine: String {
        switch source {
        case .rawTherapee: return "Look from the RawTherapee Film Simulation Collection (Pat David et al., CC BY-SA 4.0)."
        case .t3mujinpack: return "Look from t3mujinpack by João Almeida (MIT)."
        case .spektrafilm: return "Simulated from the film's spectral data — spektrafilm by Andrea Volpato (CC BY-SA 4.0)."
        }
    }

    public static func variantName(_ v: Int) -> String {
        switch v {
        case -1: return "−"
        case 0: return "Normal"
        case 1: return "+"
        default: return "++"
        }
    }
}

/// The catalogue of film looks and their colour tables.
public final class FilmLooks: @unchecked Sendable {
    public static let shared = FilmLooks()

    public let looks: [FilmLook]
    public func look(_ id: String?) -> FilmLook? {
        guard let id else { return nil }
        let i = Self.aliases[id] ?? id
        return looks.first { $0.id == i }
    }

    public static let categories: [(FilmLook.Kind, String)] = [
        (.colorNegative, "Color negative"), (.slide, "Slide"), (.blackAndWhite, "Black & white"), (.cinema, "Cinema"), (.instant, "Instant"),
    ]

    /// Ids of looks from earlier versions.
    static let aliases: [String: String] = ["kodak_portra_800_push1": "kodak_portra_800", "kodak_vision3_250d": "cinestill_50d",
                                            "kodak_vision3_50d": "cinestill_50d"]

    /// Size of each stored table (points per axis).
    public static let tableSize = 48

    private init() {
        func g(_ gran: Double, _ coarse: Double, _ fine: Double, _ rough: Double, _ colour: Double) -> GrainCharacter {
            GrainCharacter(granularity: gran, coarseRadius: coarse, fineRadius: fine, roughness: rough, colour: colour)
        }
        let ah = SIMD3<Double>(0.035, 0.010, 0), bwHal = SIMD3<Double>(repeating: 0.02), none = SIMD3<Double>(repeating: 0)
        func neg(_ id: String, _ name: String, _ v: [Int: String], gran: Double, rough: Double = 0.58, src: FilmLook.Source = .rawTherapee, _ note: String) -> FilmLook {
            FilmLook(id: id, name: name, kind: .colorNegative, variants: v, spectralStock: nil, grain: g(gran, 6.0, 1.3, rough, 0.25),
                     halation: ah, halationRadius: 65, note: note, source: src)
        }
        func slide(_ id: String, _ name: String, _ file: String, gran: Double, _ note: String) -> FilmLook {
            FilmLook(id: id, name: name, kind: .slide, variants: [0: file], spectralStock: nil, grain: g(gran, 4.5, 1.0, 0.45, 0.2),
                     halation: ah * 0.8, halationRadius: 60, note: note, source: .rawTherapee)
        }
        func bw(_ id: String, _ name: String, _ v: [Int: String], gran: Double, coarse: Double = 5.5, rough: Double = 0.6, _ note: String) -> FilmLook {
            FilmLook(id: id, name: name, kind: .blackAndWhite, variants: v, spectralStock: nil, grain: g(gran, coarse, 1.15, rough, 0),
                     halation: bwHal, halationRadius: 60, note: note, source: .rawTherapee)
        }
        func push(_ base: String, _ files: [String]) -> [Int: String] {
            Dictionary(uniqueKeysWithValues: zip([-1, 0, 1, 2], files.map { "\(base) \($0)" }))
        }
        func instant(_ id: String, _ name: String, _ v: [Int: String], _ note: String) -> FilmLook {
            FilmLook(id: id, name: name, kind: .instant, variants: v, spectralStock: nil, grain: g(5, 4.0, 1.0, 0.35, 0.2),
                     halation: none, halationRadius: 60, note: note, source: .rawTherapee)
        }
        looks = [
            // Colour negative
            neg("kodak_portra_160", "Kodak Portra 160", push("Kodak Portra 160", ["1 -", "2", "3 +", "4 ++"]), gran: 8, rough: 0.5,
                "Soft, natural skin tones and very fine grain."),
            neg("kodak_portra_400", "Kodak Portra 400", push("Kodak Portra 400", ["1 -", "2", "3 +", "4 ++"]), gran: 11, rough: 0.55,
                "The classic: warm, gentle contrast, forgiving highlights."),
            neg("kodak_portra_800", "Kodak Portra 800", push("Kodak Portra 800", ["1 -", "2", "3 +", "4 ++"]), gran: 14, rough: 0.6,
                "Warmer and grainier, made for low light."),
            neg("kodak_ektar_100", "Kodak Ektar 100", [0: "Kodak Ektar 100"], gran: 6, rough: 0.45,
                "Vivid and saturated, the finest-grained colour negative."),
            neg("kodak_gold_200", "Kodak Gold 200", [0: "t3 Kodak Gold 200"], gran: 12, src: .t3mujinpack, "Golden, nostalgic consumer colour."),
            neg("kodak_ultramax_400", "Kodak UltraMax 400", [0: "t3 Kodak Ultra Max 400"], gran: 14, rough: 0.64, src: .t3mujinpack,
                "Punchy consumer colour with visible grain."),
            neg("kodak_colorplus_200", "Kodak ColorPlus 200", [0: "t3 Kodak ColorPlus 200"], gran: 13, src: .t3mujinpack,
                "Budget film with warm, slightly muted colour."),
            neg("fujifilm_pro_400h", "Fujifilm Pro 400H", push("Fuji 400H", ["1 -", "2", "3 +", "4 ++"]), gran: 11, rough: 0.55,
                "Airy pastels, soft greens and cool shadows."),
            neg("fujifilm_pro_160c", "Fujifilm Pro 160C", push("Fuji 160C", ["1 -", "2", "3 +", "4 ++"]), gran: 8, rough: 0.5,
                "Clean, contrasty professional colour."),
            neg("fujifilm_c200", "Fujifilm Superia 200 / C200", [0: "Fuji Superia 200"], gran: 12, "Fresh greens and cool shadows."),
            neg("fujifilm_xtra_400", "Fujifilm Superia X-TRA 400", push("Fuji Superia 400", ["1 -", "2", "3 +", "4 ++"]), gran: 14, rough: 0.62,
                "Fujicolor's everyday film: green-leaning and contrasty."),
            neg("fujifilm_superia_800", "Fujifilm Superia 800", push("Fuji Superia 800", ["1 -", "2", "3 +", "4 ++"]), gran: 16, rough: 0.66,
                "Fast consumer colour."),
            neg("fujifilm_superia_1600", "Fujifilm Superia 1600", push("Fuji Superia 1600", ["1 -", "2", "3 +", "4 ++"]), gran: 19, rough: 0.7,
                "Very fast, grainy, cool-green night film."),
            neg("fujifilm_reala_100", "Fujifilm Superia Reala 100", [0: "Fuji Superia Reala 100"], gran: 8, rough: 0.5,
                "Faithful colour with a fourth colour layer."),
            neg("agfa_vista_200", "Agfa Vista 200", [0: "Agfa Vista 200"], gran: 12, "Saturated reds, cheerful consumer colour."),
            // Slides
            slide("kodak_kodachrome_25", "Kodak Kodachrome 25", "Kodak Kodachrome 25", gran: 8, "The finest Kodachrome: rich, deep and sharp."),
            slide("kodak_kodachrome_64", "Kodak Kodachrome 64", "Kodak Kodachrome 64", gran: 10,
                  "Deep reds and blues, dense shadows — the National Geographic look."),
            slide("kodak_kodachrome_200", "Kodak Kodachrome 200", "Kodak Kodachrome 200", gran: 13, "Faster Kodachrome, warmer and grainier."),
            slide("kodak_ektachrome_100", "Kodak Ektachrome E100", "Kodak E-100 GX Ektachrome 100", gran: 8, "Clean, neutral-to-cool slide film."),
            slide("kodak_ektachrome_100vs", "Kodak Ektachrome 100VS", "Kodak Ektachrome 100 VS", gran: 9, "Ektachrome with very saturated colour."),
            slide("kodak_elite_chrome_200", "Kodak Elite Chrome 200", "Kodak Elite Chrome 200", gran: 11, "Consumer slide film, warm and bright."),
            slide("fujifilm_velvia_50", "Fujifilm Velvia 50", "Fuji Velvia 50", gran: 9, "Legendary landscape film: intense colour and contrast."),
            slide("fujifilm_velvia_100", "Fujifilm Velvia 100", "Fuji Velvia 100 Generic", gran: 8, "Extremely saturated landscapes."),
            slide("fujifilm_provia_100f", "Fujifilm Provia 100F", "Fuji Provia 100F", gran: 8, "Accurate, neutral slide film."),
            slide("fujifilm_provia_400x", "Fujifilm Provia 400X", "Fuji Provia 400X", gran: 11, "Fast, neutral slide film."),
            slide("fujifilm_astia_100f", "Fujifilm Astia 100F", "Fuji Astia 100F", gran: 7, "Soft slide film made for skin tones."),
            // Black & white
            bw("ilford_hp5_plus", "Ilford HP5 Plus 400", push("Ilford HP5", ["1 -", "2", "3 +", "4 ++"]), gran: 16, coarse: 5.5, rough: 0.6,
               "Forgiving, mid-contrast classic with smooth, visible grain."),
            bw("kodak_trix_400", "Kodak Tri-X 400", push("Kodak TRI-X 400", ["1 -", "2", "4 +", "5 ++"]), gran: 17, coarse: 6.0, rough: 0.72,
               "Punchy contrast and gritty grain — the photojournalist's film."),
            bw("ilford_delta_100", "Ilford Delta 100", [0: "Ilford Delta 100"], gran: 8, coarse: 4.5, rough: 0.45, "Modern, very fine-grained and sharp."),
            bw("ilford_delta_400", "Ilford Delta 400", [0: "Ilford Delta 400"], gran: 12, coarse: 5.0, rough: 0.5, "Fine grain for a 400 film."),
            bw("ilford_delta_3200", "Ilford Delta 3200", push("Ilford Delta 3200", ["1 -", "2", "3 +", "4 ++"]), gran: 40, coarse: 7.0, rough: 0.75,
               "Very fast film with big, soft grain."),
            bw("ilford_fp4_plus", "Ilford FP4 Plus 125", [0: "Ilford FP4 Plus 125"], gran: 10, coarse: 5.0, rough: 0.5, "Traditional medium-speed film, fine grain."),
            bw("ilford_panf_plus", "Ilford Pan F Plus 50", [0: "Ilford Pan F Plus 50"], gran: 5, coarse: 4.0, rough: 0.4, "Slow film: extremely fine grain, rich contrast."),
            bw("ilford_xp2", "Ilford XP2 Super 400", [0: "Ilford XP2"], gran: 9, coarse: 5.0, rough: 0.35, "Chromogenic black & white: smooth, soft grain."),
            bw("kodak_tmax_100", "Kodak T-Max 100", [0: "Kodak T-Max 100"], gran: 8, coarse: 4.5, rough: 0.45, "Very fine grain and crisp tones."),
            bw("kodak_tmax_400", "Kodak T-Max 400", [0: "Kodak T-Max 400"], gran: 11, coarse: 5.0, rough: 0.5, "Sharp, fine-grained 400 film."),
            bw("kodak_tmax_3200", "Kodak T-Max P3200", push("Kodak TMAX 3200", ["1 -", "2", "4 +", "5 ++"]), gran: 36, coarse: 7.0, rough: 0.72,
               "Fast, high-contrast night film."),
            bw("fujifilm_acros_100", "Fujifilm Neopan Acros 100", [0: "Fuji Neopan Acros 100"], gran: 6, coarse: 4.2, rough: 0.42,
               "Smooth tones and very fine grain."),
            bw("fujifilm_neopan_1600", "Fujifilm Neopan 1600", push("Fuji Neopan 1600", ["1 -", "2", "3 +", "4 ++"]), gran: 24, coarse: 6.5, rough: 0.7,
               "Fast and contrasty, coarse grain."),
            bw("agfa_apx_100", "Agfa APX 100", [0: "Agfa APX 100"], gran: 10, coarse: 5.0, rough: 0.5, "Classic European look, gentle contrast."),
            // Cinema (simulated physically)
            FilmLook(id: "kodak_vision3_500t", name: "CineStill 800T", kind: .cinema, variants: [:], spectralStock: "kodak_vision3_500t",
                     grain: g(13, 6.5, 1.4, 0.6, 0.3), halation: SIMD3(0.30, 0.09, 0.008), halationRadius: 110,
                     note: "Tungsten-balanced cinema film without its anti-halation layer: red glow around lights. Looks cool in daylight.",
                     source: .spektrafilm),
            FilmLook(id: "cinestill_50d", name: "CineStill 50D", kind: .cinema, variants: [:], spectralStock: "kodak_vision3_50d",
                     grain: g(6, 5.0, 1.1, 0.45, 0.25), halation: SIMD3(0.21, 0.063, 0.006), halationRadius: 95,
                     note: "Daylight cinema film: extremely fine grain, wide latitude, soft red glow on highlights.", source: .spektrafilm),
            // Instant
            instant("polaroid_690", "Polaroid 690", push("Polaroid 690", ["2 -", "3", "4 +", "5 ++"]), "Warm, faded instant colour."),
            instant("fujifilm_fp100c", "Fujifilm FP-100C", push("Fuji FP-100c", ["2 -", "3", "5 +", "6 ++"]), "Peel-apart instant film: cool, soft and pastel."),
        ]
    }

    // MARK: Colour tables

    /// One look's table: `tableSize`³ entries of display RGB (sRGB-encoded), red fastest.
    public struct Table: Sendable {
        public let size: Int
        public let values: [SIMD4<Float>]
        public init(size: Int, values: [SIMD4<Float>]) { self.size = size; self.values = values }

        /// Trilinear lookup of an sRGB-encoded colour (clamped to the cube).
        public func lookup(_ c: SIMD3<Float>) -> SIMD3<Float> {
            let n = size
            let x = simd_clamp(c, .zero, .one) * Float(n - 1)
            let i0 = SIMD3<Int>(min(Int(x.x), n - 2), min(Int(x.y), n - 2), min(Int(x.z), n - 2))
            let t = x - SIMD3<Float>(Float(i0.x), Float(i0.y), Float(i0.z))
            func at(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> { let v = values[(k * n + j) * n + i]; return SIMD3(v.x, v.y, v.z) }
            let c00 = simd_mix(at(i0.x, i0.y, i0.z), at(i0.x + 1, i0.y, i0.z), SIMD3(repeating: t.x))
            let c10 = simd_mix(at(i0.x, i0.y + 1, i0.z), at(i0.x + 1, i0.y + 1, i0.z), SIMD3(repeating: t.x))
            let c01 = simd_mix(at(i0.x, i0.y, i0.z + 1), at(i0.x + 1, i0.y, i0.z + 1), SIMD3(repeating: t.x))
            let c11 = simd_mix(at(i0.x, i0.y + 1, i0.z + 1), at(i0.x + 1, i0.y + 1, i0.z + 1), SIMD3(repeating: t.x))
            return simd_mix(simd_mix(c00, c10, SIMD3(repeating: t.y)), simd_mix(c01, c11, SIMD3(repeating: t.y)), SIMD3(repeating: t.z))
        }
    }

    private let lock = NSLock()
    private var tables: [String: Table]?

    /// The table of a look's variant (the standard one when the variant does not exist).
    public func table(_ look: FilmLook, variant: Int) -> Table? {
        guard let file = look.variants[variant] ?? look.variants[0] else { return nil }
        lock.lock(); defer { lock.unlock() }
        if tables == nil { tables = Self.loadTables() }
        return tables?[file]
    }

    /// Resources/FilmLooks.lzfse (LZFSE-compressed): "PLK3", size n, count, then per table a UTF-8 name (UInt16
    /// length) and its n³ × RGB values as 12-bit codes (the sources are 8-bit; interpolation between grid points
    /// keeps gradients continuous). Stored per channel as the difference from identity, predicted from the
    /// neighbouring grid points (Lorenzo predictor), zig-zag coded, high bytes then low bytes — about tenfold
    /// smaller after compression.
    private static func loadTables() -> [String: Table] {
        guard let url = Bundle.module.url(forResource: "FilmLooks", withExtension: "lzfse"),
              let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return [:] }
        return decode(data)
    }

    static func decode(_ data: Data) -> [String: Table] {
        var out: [String: Table] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var o = 0
            func u32() -> Int { defer { o += 4 }; return Int(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian) }
            func u16() -> Int { defer { o += 2 }; return Int(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self).littleEndian) }
            guard raw.count > 12, String(decoding: raw[0..<4], as: UTF8.self) == "PLK3" else { return }
            o = 4
            let n = u32(), count = u32()
            let cells = n * n * n, m = cells * 3
            for _ in 0..<count {
                let len = u16()
                let name = String(decoding: raw[o..<(o + len)], as: UTF8.self)
                o += len
                var values = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: cells)
                var r = [Int32](repeating: 0, count: cells)
                for ch in 0..<3 {
                    for idx in 0..<cells {
                        let at = ch * cells + idx
                        let z = Int32(UInt16(raw[o + at]) << 8 | UInt16(raw[o + m + at]))
                        let e = (z >> 1) ^ -(z & 1)
                        r[idx] = e + Self.lorenzo(r, idx, n)
                        let i = idx % n, j = (idx / n) % n, k = idx / (n * n)
                        let id = Self.identityCode([i, j, k][ch], n)
                        values[idx][ch] = Float(id + r[idx]) / 4095
                    }
                }
                o += 2 * m
                out[name] = Table(size: n, values: values)
            }
        }
        return out
    }

    static func identityCode(_ i: Int, _ n: Int) -> Int32 { Int32((Double(i) / Double(n - 1) * 4095).rounded()) }

    /// Prediction of r[idx] from its already-decoded neighbours (i−1, j−1, k−1 corners of the cell).
    static func lorenzo(_ r: [Int32], _ idx: Int, _ n: Int) -> Int32 {
        let i = idx % n, j = (idx / n) % n, k = idx / (n * n)
        func v(_ di: Int, _ dj: Int, _ dk: Int) -> Int32 {
            let a = i - di, b = j - dj, c = k - dk
            return a < 0 || b < 0 || c < 0 ? 0 : r[(c * n + b) * n + a]
        }
        return v(1, 0, 0) + v(0, 1, 0) + v(0, 0, 1) - v(1, 1, 0) - v(1, 0, 1) - v(0, 1, 1) + v(1, 1, 1)
    }

    /// Writes tables in the resource format (used by `positives-cli make-looks`; compress with LZFSE).
    public static func encode(_ tables: [(String, Table)]) -> Data {
        var d = Data("PLK3".utf8)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        u32(tables.first?.1.size ?? 0); u32(tables.count)
        for (name, t) in tables {
            let b = Data(name.utf8)
            u16(b.count); d.append(b)
            let n = t.size, cells = n * n * n
            var hi = [UInt8](), lo = [UInt8]()
            for ch in 0..<3 {
                var r = [Int32](repeating: 0, count: cells)
                for idx in 0..<cells {
                    let i = idx % n, j = (idx / n) % n, k = idx / (n * n)
                    let q = Int32((min(max(t.values[idx][ch], 0), 1) * 4095).rounded())
                    r[idx] = q - identityCode([i, j, k][ch], n)
                }
                for idx in 0..<cells {
                    let e = r[idx] - lorenzo(r, idx, n)
                    let z = UInt16(truncatingIfNeeded: (e << 1) ^ (e >> 31))
                    hi.append(UInt8(z >> 8)); lo.append(UInt8(z & 0xFF))
                }
            }
            d.append(contentsOf: hi); d.append(contentsOf: lo)
        }
        return d
    }
}
