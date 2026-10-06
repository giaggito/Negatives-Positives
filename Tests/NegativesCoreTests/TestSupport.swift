import CoreGraphics
import Foundation
import simd
@testable import NegativesCore

// MARK: - Reference scene

enum ColorChecker {
    /// Classic 24-patch chart, sRGB 8-bit (D65).
    static let sRGB8: [(String, SIMD3<Double>)] = [
        ("dark skin", [115, 82, 68]), ("light skin", [194, 150, 130]), ("blue sky", [98, 122, 157]),
        ("foliage", [87, 108, 67]), ("blue flower", [133, 128, 177]), ("bluish green", [103, 189, 170]),
        ("orange", [214, 126, 44]), ("purplish blue", [80, 91, 166]), ("moderate red", [193, 90, 99]),
        ("purple", [94, 60, 108]), ("yellow green", [157, 188, 64]), ("orange yellow", [224, 163, 46]),
        ("blue", [56, 61, 150]), ("green", [70, 148, 73]), ("red", [175, 54, 60]),
        ("yellow", [231, 199, 31]), ("magenta", [187, 86, 149]), ("cyan", [8, 133, 161]),
        ("white", [243, 243, 243]), ("neutral 8", [200, 200, 200]), ("neutral 6.5", [160, 160, 160]),
        ("neutral 5", [122, 122, 122]), ("neutral 3.5", [85, 85, 85]), ("black", [52, 52, 52]),
    ]

    static func linear(_ c: Double) -> Double { let v = c / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }

    /// Scene-linear Rec.2020 values of the patches.
    static var rec2020: [(String, SIMD3<Double>)] {
        sRGB8.map { ($0.0, ColorScience.sRGBToRec2020 * SIMD3(linear($0.1.x), linear($0.1.y), linear($0.1.z))) }
    }

    static let middleGreyIndex = 21  // neutral 5
}

/// The X-E4 camera → linear sRGB matrix as reported by LibRaw (rows sum to 1).
let xe4CameraToSRGB = simd_double3x3(rows: [
    SIMD3(1.2384, 0.0315, -0.2699),
    SIMD3(-0.1470, 1.5570, -0.4100),
    SIMD3(0.0037, -0.3954, 1.3916),
])

/// Scene Rec.2020 -> camera-balanced RGB for the synthetic camera.
func cameraBalanced(fromRec2020 v: SIMD3<Double>) -> SIMD3<Double> {
    (ColorScience.sRGBToRec2020 * xe4CameraToSRGB).inverse * v
}

/// Builds a synthetic scan: rebate strip on top, colour checker patches and a grey ramp spanning the
/// scene's darkest to brightest values (so automatic anchors land on neutrals, as in a real scene).
struct SyntheticScan {
    let image: LinearImage
    /// Centre pixel of each colour checker patch.
    let patchCentres: [SIMD2<Int>]
    let rebateRect: CGRect

    init(film: SyntheticFilm, exposure: Double = 1, patchSize: Int = 24) {
        let cols = 6, rows = 4
        let w = cols * patchSize, rampH = patchSize, rebateH = patchSize / 2
        let h = rebateH + rows * patchSize + rampH
        var img = LinearImage(width: w, height: h)
        let rebate = SIMD3<Float>(film.rebate)
        for y in 0..<rebateH { for x in 0..<w { img[x, y] = rebate } }
        var centres: [SIMD2<Int>] = []
        for (i, p) in ColorChecker.rec2020.enumerated() {
            let cx = (i % cols) * patchSize, cy = rebateH + (i / cols) * patchSize
            let v = SIMD3<Float>(film.scan(exposure: cameraBalanced(fromRec2020: p.1) * exposure))
            for y in cy..<(cy + patchSize) { for x in cx..<(cx + patchSize) { img[x, y] = v } }
            centres.append(SIMD2(cx + patchSize / 2, cy + patchSize / 2))
        }
        // Grey ramp from black patch to white patch reflectance (log-spaced).
        let lo = log10(0.03), hi = log10(0.92)
        for x in 0..<w {
            let g = pow(10, lo + (hi - lo) * Double(x) / Double(w - 1))
            let v = SIMD3<Float>(film.scan(exposure: SIMD3(repeating: g * exposure)))
            for y in (h - rampH)..<h { img[x, y] = v }
        }
        image = img
        patchCentres = centres
        rebateRect = CGRect(x: 0, y: 0, width: 1, height: Double(rebateH) / Double(h))
    }
}

extension SIMD3 where Scalar == Double {
    var maxAbs: Double { Swift.max(abs(x), Swift.max(abs(y), abs(z))) }
}
