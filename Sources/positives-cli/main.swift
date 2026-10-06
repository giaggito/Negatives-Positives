import Foundation
import PositivesCore

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let usage = """
positives-cli — the Positives photo editor's engine from the command line

USAGE
  positives-cli render <photo> [out dir] [--format jpeg|tiff16|tiff32|heic|png8] [--space srgb|p3|adobe|prophoto|rec2020]
                [--set key=value …]          keys: exposure contrast highlights shadows whites blacks clarity texture
                                              dehaze vibrance saturation temperature tint profile …
                [--layer <photo>]            double exposure (then --set lblend= lamount= lexposure= lsize= langle= lmask=)
                [--long <px> | --print <cm>@<dpi>] [--sharpen screen|glossy|matte[:0|1|2]]
  positives-cli make-looks <HaldCLUT dir> <out.lzfse>   rebuild the film look tables
"""

func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let t = Date()
    let r = try body()
    print(String(format: "  %@: %.3f s", label, Date().timeIntervalSince(t)))
    return r
}

func applySetting(_ e: inout EditState, _ kv: String) throws {
    let parts = kv.split(separator: "=", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { throw ExportError.write("bad --set \(kv)") }
    let v = Double(parts[1]) ?? 0
    switch parts[0] {
    case "exposure": e.light.exposure = v
    case "contrast": e.light.contrast = v
    case "highlights": e.light.highlights = v
    case "shadows": e.light.shadows = v
    case "whites": e.light.whites = v
    case "blacks": e.light.blacks = v
    case "clarity": e.presence.clarity = v
    case "texture": e.presence.texture = v
    case "dehaze": e.presence.dehaze = v
    case "vibrance": e.color.vibrance = v
    case "saturation": e.color.saturation = v
    case "temperature": e.whiteBalance = WhiteBalance(temperature: v, tint: e.whiteBalance?.tint ?? 0)
    case "tint": e.whiteBalance = WhiteBalance(temperature: e.whiteBalance?.temperature ?? WhiteBalance.referenceTemperature, tint: v)
    case "profile": e.profile = ToneProfile(rawValue: parts[1])
    case "film": e.film.stock = parts[1] == "none" ? nil : parts[1]
    case "paper": e.film.paper = parts[1]
    case "grain": e.grain.amount = v
    case "grainsize": e.grain.size = v
    case "softness": e.grain.softness = v
    case "halation": e.film.halation = v
    case "bloom": e.effects.bloom.amount = v
    case "bwfilter": e.film.bwFilter = BWFilter(rawValue: parts[1]) ?? .none
    case "dr": e.recipe.dynamicRange = Int(v)
    case "htone": e.recipe.highlight = v
    case "stone": e.recipe.shadow = v
    case "chrome": e.color.colorChrome = v
    case "chromeblue": e.color.colorChromeBlue = v
    case "vignette": e.effects.vignette.amount = v
    // Settings of the last layer (--layer).
    case "lblend": if !e.layers.isEmpty { e.layers[e.layers.count - 1].blend = PhotoLayer.Blend(rawValue: parts[1]) ?? .film }
    case "lamount": if !e.layers.isEmpty { e.layers[e.layers.count - 1].amount = v }
    case "lexposure": if !e.layers.isEmpty { e.layers[e.layers.count - 1].exposure = v }
    case "lsize": if !e.layers.isEmpty { e.layers[e.layers.count - 1].size *= v }
    case "langle": if !e.layers.isEmpty { e.layers[e.layers.count - 1].angle += v }
    case "lmask":
        // subject, sky, people (prefix "not-" to invert)
        if !e.layers.isEmpty {
            let inv = parts[1].hasPrefix("not-")
            var c = MaskComponent(kind: MaskComponent.Kind(rawValue: inv ? String(parts[1].dropFirst(4)) : parts[1]) ?? .subject)
            c.invert = inv
            e.layers[e.layers.count - 1].mask.components = [c]
        }
    default: throw ExportError.write("unknown key \(parts[0])")
    }
}

do {
    switch args.first {
    case "render" where args.count >= 2:
        let url = URL(fileURLWithPath: args[1])
        var outDir = URL(fileURLWithPath: "positives-out")
        var options = ExportOptions()
        var sets: [String] = []
        var output = OutputSettings()
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--format": options.format = ExportFormat(rawValue: args[i + 1]) ?? .jpeg; i += 2
            case "--space":
                let m: [String: OutputColorSpace] = ["srgb": .sRGB, "p3": .displayP3, "adobe": .adobeRGB, "prophoto": .proPhoto, "rec2020": .rec2020]
                options.space = m[args[i + 1].lowercased()] ?? .sRGB; i += 2
            case "--set": sets.append(args[i + 1]); i += 2
            case "--layer": sets.append("layer=" + args[i + 1]); i += 2
            case "--long": output.size = .longEdge; output.longEdge = Int(args[i + 1]) ?? 2048; i += 2
            case "--print":
                // e.g. 30@300 = 30 cm long side at 300 dpi
                let v = args[i + 1].split(separator: "@").compactMap { Double($0) }
                output.size = .print; output.printLongCM = v.first ?? 30; output.dpi = v.count > 1 ? v[1] : 300
                options.dpi = output.dpi; i += 2
            case "--sharpen":
                let v = args[i + 1].split(separator: ":").map(String.init)
                output.sharpening = OutputSettings.Sharpening(rawValue: v[0]) ?? .none
                output.strength = v.count > 1 ? (Int(v[1]) ?? 1) : 1; i += 2
            default: outDir = URL(fileURLWithPath: args[i]); i += 1
            }
        }
        let engine = try RenderEngine(context: MetalContext.shared!)
        let src = try time("decode") { try SourceLoader.load(url: url) }
        print("  \(src.cameraDescription) \(src.image.width)×\(src.image.height), as shot \(Int(src.asShotWhiteBalance.temperature)) K / \(Int(src.asShotWhiteBalance.tint)), baseline \(String(format: "%+.2f", src.baselineExposure)) EV")
        var e = EditState.initial(for: src)
        for s in sets {
            if s.hasPrefix("layer=") {
                let lurl = URL(fileURLWithPath: String(s.dropFirst(6)))
                let ls = try SourceLoader.load(url: lurl, proxy: true)
                e.layers.append(LayerMath.place(PhotoLayer(path: lurl.path), frame: LayerMath.Frame(ls),
                                                photoSensor: (src.fullSize.width, src.fullSize.height), geometry: e.geometry))
            } else {
                try applySetting(&e, s)
            }
        }
        let r = try time("render + write") {
            try PhotoExport.export(photo: url, edit: e, options: options, to: outDir, engine: engine, source: src, output: output)
        }
        print("  wrote \(r.url.path) — \(r.report.width)×\(r.report.height), \(r.report.bytes / 1024) KB, clipped \(String(format: "%.4f", r.report.clippedFraction * 100)) %")
    case "make-looks" where args.count >= 3:
        // How Resources/FilmLooks.lzfse was made from the HaldCLUT collections (see FILM_LOOKS_LICENSE.txt).
        try MakeLooks.run(dir: URL(fileURLWithPath: args[1]), out: URL(fileURLWithPath: args[2]), analyze: args.contains("--analyze"))
    default:
        print(usage)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
