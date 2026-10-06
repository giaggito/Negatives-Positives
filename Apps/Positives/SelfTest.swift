import AppKit
import PositivesCore
import SwiftUI
import UniformTypeIdentifiers

/// `Positives --self-test <out dir> <folder>`: drives the real app (open, edit, drag sliders, zoom, crop,
/// history, next photo), saves window and canvas pictures and a log with frame times measured inside the app.
@MainActor
enum SelfTest {
    static var log = ""
    static var manualWindow: NSWindow?
    static var running = false
    static var activity: NSObjectProtocol?

    static func note(_ s: String) {
        log += s + "\n"
        NSLog("SELFTEST %@", s)
    }

    static func run(model: EditorModel, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        self.model = model
        running = true
        // Keep App Nap from throttling the simulated drags when the app is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled], reason: "Self-test")
        // Start from unedited photos: forget archive entries left by earlier runs — only for temporary folders.
        for e in Archive.shared.entries where e.path.hasPrefix("/private/tmp/") || e.path.hasPrefix("/tmp/") || e.path.hasPrefix(NSTemporaryDirectory()) {
            Archive.shared.remove(e.id)
        }
        model.archived = Archive.shared.entries
        Task { @MainActor in
            note("start \(Date())")
            note("windows: \(NSApp.windows.map { "\($0.title) visible=\($0.isVisible) frame=\($0.frame)" })")
            if !NSApp.windows.contains(where: { $0.isVisible }) {
                // The session is locked (no scene windows): build the same window by hand so everything lays out.
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.appearance = NSAppearance(named: .darkAqua)
                w.contentView = NSHostingView(rootView: MainView(model: model).preferredColorScheme(.dark))
                w.orderFrontRegardless()
                manualWindow = w
                try? await Task.sleep(for: .milliseconds(800))
                note("manual window: \(w.frame), visible \(w.isVisible)")
            }
            let t0 = Date()
            await waitFor(60) { model.source != nil }
            note(String(format: "first picture (quick proxy) after %.2f s", Date().timeIntervalSince(t0)))
            await waitFor(60) { model.source?.isProxy == false && model.isSettled }
            note(String(format: "full quality + exact render after %.2f s", Date().timeIntervalSince(t0)))
            snap(model, out, "01-opened")

            model.change("Self-test look") { e in
                e.light.exposure = 0.3; e.light.shadows = 45; e.light.highlights = -50; e.light.contrast = 15
                e.presence.clarity = 25; e.color.vibrance = 25
            }
            await waitFor(10) { model.isSettled }
            snap(model, out, "02-edited")

            // Stage 2: colour and curves.
            model.category = .color
            model.change("Self-test colour") { e in
                e.mixer.saturation[3] = -40; e.mixer.hue[1] = 20; e.mixer.luminance[5] = -35
                e.grading.shadows.hue = 220; e.grading.shadows.saturation = 35; e.grading.highlights.hue = 55; e.grading.highlights.saturation = 30
            }
            let size = model.displaySize
            model.pickTargetColor(at: CGPoint(x: size.width * 0.5, y: size.height * 0.12))   // the sky
            await waitFor(5) { !model.edit.targeted.isEmpty }
            note("picked colour: \(model.edit.targeted.first.map { String(format: "hue %.0f° chroma %.3f L %.2f", $0.hue, $0.chroma, $0.lightness) } ?? "none")")
            model.change("Self-test isolate") { $0.targeted[0].isolate = 100; $0.targeted[0].width = 30 }
            await waitFor(10) { model.isSettled }
            snap(model, out, "11-color")
            let saved = model.expanded
            model.expanded = ["targeted"]
            model.targetSelection = 0
            try? await Task.sleep(for: .milliseconds(300))
            snap(model, out, "11b-targeted")
            model.expanded = ["grading"]
            model.gradingZone = 0
            try? await Task.sleep(for: .milliseconds(300))
            snap(model, out, "11c-grading")
            model.expanded = saved
            model.showTargetOverlay = true
            await waitFor(10) { model.isSettled }
            snap(model, out, "12-target-overlay")
            model.showTargetOverlay = false
            model.change("No isolate") { $0.targeted[0].isolate = 0; $0.targeted[0].saturation = 40 }
            model.category = .curves
            model.change("Self-test curve") { $0.curves.master = [CurvePoint(0, 0.04), CurvePoint(0.25, 0.2), CurvePoint(0.75, 0.82), CurvePoint(1, 1)] }
            model.curveChannel = .master
            model.pickCurvePoint(at: CGPoint(x: size.width * 0.5, y: size.height * 0.6))
            await waitFor(5) { model.edit.curves.master.count == 5 }
            note("curve points after pipette: \(model.edit.curves.master.map { String(format: "(%.2f, %.2f)", $0.x, $0.y) })")
            await waitFor(10) { model.isSettled }
            snap(model, out, "13-curves")
            await drag(model, "Curve point (fit view)") { e, i in
                e.curves.master = [CurvePoint(0, 0.04), CurvePoint(0.25, 0.2 + 0.05 * sin(Double(i) / 9)), CurvePoint(0.75, 0.82), CurvePoint(1, 1)]
            }
            await drag(model, "Grading wheel (fit view)") { e, i in e.grading.midtones.hue = Double(i * 4); e.grading.midtones.saturation = 30 }
            await drag(model, "Mixer saturation (fit view)") { e, i in e.mixer.saturation[5] = 50 * sin(Double(i) / 9) }

            // Stage 3: film looks, grain, halation, bloom, vignette.
            model.category = .film
            let tp = Date()
            await waitFor(20) { model.filmPreviews.count > 40 }
            note(String(format: "film previews: %d after %.2f s", model.filmPreviews.count, Date().timeIntervalSince(tp)))
            snap(model, out, "14a-film-browser")
            model.setFilm("kodak_portra_400")
            await waitFor(15) { model.isSettled }
            snap(model, out, "14-portra400")
            await drag(model, "Exposure with Portra 400 (fit view)") { $0.light.exposure = 0.3 + 0.6 * sin(Double($1) / 9) }
            await drag(model, "Grain amount (fit view)") { $0.grain.amount = 100 + 60 * sin(Double($1) / 9) }
            await drag(model, "Grain size (fit view)") { $0.grain.size = 100 + 60 * sin(Double($1) / 9) }
            await drag(model, "Film warmth (fit view)") { $0.film.warmth = 40 * sin(Double($1) / 9) }
            model.change("Variant ++") { $0.film.variant = 2 }
            await waitFor(15) { model.isSettled }
            snap(model, out, "14b-portra400-plusplus")
            model.change("Variant standard") { $0.film.variant = 0 }
            model.setFilm("kodak_vision3_500t")
            await waitFor(15) { model.isSettled }
            snap(model, out, "15-cinestill")
            await drag(model, "Halation (fit view)") { $0.film.halation = 100 + 80 * sin(Double($1) / 9) }
            await drag(model, "Exposure with CineStill (fit view)") { $0.light.exposure = 0.3 + 0.6 * sin(Double($1) / 9) }
            model.change("Recipe") { e in
                e.recipe.dynamicRange = 200; e.recipe.highlight = -1; e.recipe.shadow = 1; e.recipe.color = 2
                e.recipe.redShift = 2; e.recipe.blueShift = -3; e.color.colorChrome = 100; e.color.colorChromeBlue = 50
            }
            await waitFor(15) { model.isSettled }
            snap(model, out, "15b-recipe")
            await drag(model, "Recipe highlight (fit view)") { $0.recipe.highlight = 1.5 * sin(Double($1) / 9) }
            model.filmTab = 2
            model.setFilm("ilford_hp5_plus")
            model.change("Red filter") { $0.film.bwFilter = .red }
            await waitFor(15) { model.isSettled }
            snap(model, out, "16-hp5")
            model.setFilm("kodak_trix_400")
            await waitFor(15) { model.isSettled }
            snap(model, out, "16b-trix")
            model.filmTab = 1
            model.setFilm("kodak_kodachrome_64")
            model.expanded.insert("grainMore")
            await waitFor(15) { model.isSettled }
            snap(model, out, "17-kodachrome")
            model.category = .color
            model.change("Color Chrome strong") { $0.color.colorChrome = 100; $0.color.colorChromeBlue = 100 }
            await waitFor(15) { model.isSettled }
            snap(model, out, "17b-color-chrome")
            model.category = .effects
            model.change("Self-test effects") { $0.effects.bloom.amount = 40; $0.effects.vignette.amount = -35 }
            await waitFor(15) { model.isSettled }
            snap(model, out, "18-effects")
            await drag(model, "Bloom (fit view)") { $0.effects.bloom.amount = 40 + 30 * sin(Double($1) / 9) }
            await drag(model, "Vignette (fit view)") { $0.effects.vignette.amount = -35 + 30 * sin(Double($1) / 9) }

            // Stage 4: masks.
            model.category = .masks
            try? await Task.sleep(for: .milliseconds(400))
            model.addMask(.linear)
            model.changeMask("Sky darker") { $0.settings.exposure = -0.8; $0.settings.temperature = -30 }
            await waitFor(15) { model.isSettled }
            snap(model, out, "21-mask-linear")
            await drag(model, "Mask exposure (fit view)") { e, i in e.masks[e.masks.count - 1].settings.exposure = -0.8 + 0.6 * sin(Double(i) / 9) }
            model.addMask(.radial)
            model.changeMask("Radial") { $0.settings.exposure = 0.5; $0.settings.saturation = 30 }
            model.showMaskOverlay = true
            await waitFor(15) { model.isSettled }
            snap(model, out, "22-mask-radial-overlay")
            model.showMaskOverlay = false
            model.addMask(.brush)
            model.changeMask("Brush") { $0.settings.exposure = 1 }
            let sz = model.displaySize
            model.brushSize = 0.04
            var frames0 = model.frameLog.count
            let tb = Date()
            model.canvasDraw(.began, at: CGPoint(x: sz.width * 0.2, y: sz.height * 0.7), modifiers: [])
            for i in 1...60 {
                let t = Double(i) / 60
                model.canvasDraw(.changed, at: CGPoint(x: sz.width * (0.2 + 0.6 * t), y: sz.height * (0.7 - 0.2 * sin(t * 3))), modifiers: [])
                try? await Task.sleep(for: .milliseconds(16))
            }
            model.canvasDraw(.ended, at: CGPoint(x: sz.width * 0.8, y: sz.height * 0.6), modifiers: [])
            let paintFrames = model.frameLog.suffix(from: frames0).filter { $0.time >= tb && $0.render > 0 }
            let pr = paintFrames.map { $0.render * 1000 }.sorted()
            note(String(format: "brush painting: %.0f frames/s, render median %.1f ms, p95 %.1f ms, strokes %d", Double(paintFrames.count) / Date().timeIntervalSince(tb),
                        pr.isEmpty ? 0 : pr[pr.count / 2], pr.isEmpty ? 0 : pr[min(pr.count - 1, Int(Double(pr.count) * 0.95))],
                        model.selectedPart?.strokes.count ?? -1))
            await waitFor(15) { model.isSettled }
            model.showMaskOverlay = true
            await waitFor(15) { model.isSettled }
            snap(model, out, "23-mask-brush")
            model.showMaskOverlay = false
            let tsky = Date()
            model.addMask(.sky)
            model.changeMask("Sky") { $0.settings.exposure = -0.7 }
            model.showMaskOverlay = true
            await waitFor(30) { model.isSettled }
            note(String(format: "sky mask ready after %.2f s", Date().timeIntervalSince(tsky)))
            snap(model, out, "23b-mask-sky")
            model.showMaskOverlay = false
            frames0 = model.frameLog.count
            let ts = Date()
            model.addMask(.subject)
            model.changeMask("Subject") { $0.settings.exposure = 0.7 }
            model.showMaskOverlay = true
            await waitFor(30) { model.isSettled }
            note(String(format: "subject mask ready after %.2f s", Date().timeIntervalSince(ts)))
            snap(model, out, "24-mask-subject")
            model.showMaskOverlay = false
            await drag(model, "Mask exposure with 4 masks (fit view)") { e, i in e.masks[0].settings.exposure = -0.8 + 0.6 * sin(Double(i) / 9) }
            note("masks: \(model.edit.masks.map { "\($0.name) [\($0.components.map(\.kind.rawValue).joined(separator: ","))]" })")

            // Layers (double exposure): the folder's other photo over this one.
            if let other = model.items.first(where: { $0.url != model.source?.url })?.url {
                let tl = Date()
                model.addLayer(other)
                await waitFor(30) { !model.edit.layers.isEmpty }
                note(String(format: "layer added (quick version) after %.2f s", Date().timeIntervalSince(tl)))
                await waitFor(60) { model.layersLoading.isEmpty && model.isSettled }
                note(String(format: "layer at full quality + exact render after %.2f s", Date().timeIntervalSince(tl)))
                snap(model, out, "25-layer")
                let c0 = model.edit.layers[0].center
                await drag(model, "Move layer (fit view)") { e, i in e.layers[0].center = MaskPoint(c0.x + 0.06 * sin(Double(i) / 9), c0.y) }
                await drag(model, "Layer amount (fit view)") { e, i in e.layers[0].amount = 70 + 30 * sin(Double(i) / 9) }
                await drag(model, "Exposure with a layer (fit view)") { $0.light.exposure = 0.3 + 0.6 * sin(Double($1) / 9) }
                model.changeLayer("Screen") { $0.blend = .screen; $0.size *= 0.7; $0.angle += 12 }
                model.addPart(.sky, mode: .add)
                await waitFor(30) { model.isSettled }
                snap(model, out, "26-layer-sky")
                note("layers: \(model.edit.layers.map { "\($0.name) \($0.blend.rawValue) [\($0.mask.components.map(\.kind.rawValue).joined(separator: ","))]" })")
                model.removeLayer(model.edit.layers[0].id)
                await waitFor(30) { model.isSettled }
            }
            // Presets: hover preview, apply; pictures of the new panels.
            let tPreset = Date()
            model.previewPreset = PresetStore.builtIn.first { $0.name == "CineStill Night" }
            await waitFor(20) { model.isSettled }
            note(String(format: "preset preview settled after %.2f s", Date().timeIntervalSince(tPreset)))
            snap(model, out, "27-preset-preview")
            model.previewPreset = nil
            model.applyPreset(PresetStore.builtIn.first { $0.name == "Portra Portrait" }!)
            await waitFor(20) { model.isSettled }
            note("after preset: film \(model.edit.film.stock ?? "-"), grain \(model.edit.grain.amount), masks \(model.edit.masks.count)")
            snapView(PresetsPopover(model: model), CGSize(width: 290, height: 520), out, "28-presets-panel")
            snapView(ExportSheet(model: model, isPresented: .constant(true)), CGSize(width: 520, height: 640), out, "29-export-sheet")
            snapView(PositivesCredits(), CGSize(width: 520, height: 700), out, "30-credits")
            let te = Date()
            var o = OutputSettings(); o.size = .longEdge; o.longEdge = 2048; o.sharpening = .screen
            model.export(items: [model.current!], options: ExportOptions(), output: o, to: out.appendingPathComponent("export"))
            await waitFor(60) { model.exportProgress == nil && model.exportMessage?.hasPrefix("Exported") == true }
            note(String(format: "export 2048 px sharpened: %.2f s — %@", Date().timeIntervalSince(te), model.exportMessage ?? "-"))

            model.zoom(1)
            await waitFor(10) { model.isSettled }
            try? await Task.sleep(for: .milliseconds(500))
            snap(model, out, "19-film-zoom100")
            await drag(model, "Grain amount (100%)") { $0.grain.amount = 100 + 60 * sin(Double($1) / 9) }
            await drag(model, "Exposure with film (100%)") { $0.light.exposure = 0.3 + 0.6 * sin(Double($1) / 9) }
            model.fit()
            model.category = .light

            await drag(model, "Exposure (fit view)") { $0.light.exposure = 0.3 + 0.6 * sin(Double($1) / 9) }
            await drag(model, "Temperature (fit view)") { $0.whiteBalance = WhiteBalance(temperature: 5200 + 900 * sin(Double($1) / 9), tint: 5) }
            await drag(model, "Clarity (fit view)") { $0.presence.clarity = 25 + 30 * sin(Double($1) / 9) }

            model.zoom(1)
            await waitFor(10) { model.isSettled }
            try? await Task.sleep(for: .milliseconds(500))
            snap(model, out, "03-zoom100")
            await drag(model, "Exposure (100%)") { $0.light.exposure = 0.3 + 0.6 * sin(Double($1) / 9) }
            await drag(model, "Temperature (100%)") { $0.whiteBalance = WhiteBalance(temperature: 5200 + 900 * sin(Double($1) / 9), tint: 5) }

            model.zoom(4)
            await waitFor(10) { model.isSettled }
            try? await Task.sleep(for: .milliseconds(500))
            snap(model, out, "04-zoom400")

            model.fit()
            try? await Task.sleep(for: .milliseconds(500))
            model.showClipping = true
            await waitFor(10) { model.isSettled }
            snap(model, out, "05-clipping")
            model.showClipping = false

            model.tool = .crop
            await waitFor(10) { model.isSettled }
            try? await Task.sleep(for: .milliseconds(500))
            note("crop entry: crop = \(model.edit.geometry.crop), frame = \(model.canvasState.imageFrame), display = \(model.displaySize)")
            snap(model, out, "06-crop-entry")
            model.setCropAspect(.square)
            note("after crop ratio: \(model.history.map(\.label)) index \(model.historyIndex)")
            model.setStraighten(4)
            note("after straighten: \(model.history.map(\.label)) index \(model.historyIndex)")
            await waitFor(10) { model.isSettled }
            try? await Task.sleep(for: .milliseconds(500))
            snap(model, out, "06-crop")
            model.tool = .none
            await waitFor(10) { model.isSettled }
            try? await Task.sleep(for: .milliseconds(400))
            snap(model, out, "07-cropped")

            model.category = .history
            try? await Task.sleep(for: .milliseconds(400))
            snap(model, out, "08-history")
            let before = model.history.count
            note("history labels: \(model.history.map(\.label))")
            model.undo(); model.undo(); model.undo()
            note("history: \(before) entries, after 3× undo at index \(model.historyIndex), crop = \(model.edit.geometry.crop)")
            model.redo(); model.redo(); model.redo()
            model.category = .light

            model.showBefore = true
            await waitFor(10) { model.isSettled }
            snap(model, out, "09-before")
            model.showBefore = false

            // Archive: save, go to the start screen, continue from it.
            let savedURL = model.current?.url
            model.saveToArchive()
            note("saved: \(model.archived.first?.name ?? "-"), unsaved now \(model.currentIsUnsaved)")
            model.goHome()
            try? await Task.sleep(for: .milliseconds(600))
            snap(model, out, "20-start-screen")
            if let e = model.archived.first(where: { $0.path == savedURL?.standardizedFileURL.path }) {
                let edit = e.edit
                model.openArchived(e)
                await waitFor(30) { model.source != nil && model.isSettled }
                note("reopened from the archive: edit restored \(model.edit == edit), film \(model.edit.film.stock ?? "-"), masks \(model.edit.masks.count)")
            }

            if let item = model.current {
                let te = Date()
                let dir = out.appendingPathComponent("exports")
                model.export(items: [item], options: ExportOptions(), to: dir)
                await waitFor(60) { model.exportProgress == nil && (model.exportMessage?.hasPrefix("Exported") ?? false) }
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
                for f in files {
                    let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let props = ImageLoader.properties(url: f)
                    note(String(format: "export %@: %.1f MB, %@×%@, orientation %@, camera %@, %.1f s — %@", f.lastPathComponent, Double(size) / 1e6,
                                "\(props["PixelWidth"] ?? "?")", "\(props["PixelHeight"] ?? "?")", "\(props["Orientation"] ?? "-")",
                                "\((props["{TIFF}"] as? [String: Any])?["Model"] ?? "-")", Date().timeIntervalSince(te), model.exportMessage ?? ""))
                }
            }

            let t1 = Date()
            model.selectNext()
            await waitFor(30) { model.source != nil && model.isSettled }
            note(String(format: "next photo shown after %.2f s (prefetched: %@)", Date().timeIntervalSince(t1), model.source?.isProxy == false ? "yes" : "no"))
            snap(model, out, "10-next")

            for e in Archive.shared.entries where e.path.hasPrefix("/private/tmp/") || e.path.hasPrefix("/tmp/") || e.path.hasPrefix(NSTemporaryDirectory()) {
                Archive.shared.remove(e.id)
            }
            try? log.write(to: out.appendingPathComponent("selftest.log"), atomically: true, encoding: .utf8)
            note("done")
            NSApp.terminate(nil)
        }
    }

    /// Simulates a 1.5 s slider drag at 60 Hz and reports the frames that reached the screen.
    static func drag(_ model: EditorModel, _ name: String, _ change: @escaping (inout EditState, Int) -> Void) async {
        await waitFor(10) { model.isSettled }
        model.frameLog.removeAll()
        model.beginInteraction(name)
        let start = Date()
        for i in 0..<90 {
            model.change(name) { change(&$0, i) }
            try? await Task.sleep(for: .milliseconds(16))
        }
        let end = Date()
        model.endInteraction()
        let frames = model.frameLog.filter { $0.time >= start && $0.time <= end.addingTimeInterval(0.05) && $0.render > 0 }
        let renders = frames.map { $0.render * 1000 }.sorted()
        let fps = Double(frames.count) / end.timeIntervalSince(start)
        let med = renders.isEmpty ? 0 : renders[renders.count / 2]
        let p95 = renders.isEmpty ? 0 : renders[min(renders.count - 1, Int(Double(renders.count) * 0.95))]
        note(String(format: "drag %@: %.0f frames/s on screen, render median %.1f ms, p95 %.1f ms", name, fps, med, p95))
        let t = Date()
        await waitFor(10) { model.isSettled }
        note(String(format: "   settled to the exact render %.0f ms after release", Date().timeIntervalSince(t) * 1000))
        note("   history now \(model.history.map(\.label)) index \(model.historyIndex)")
    }

    /// A picture of a SwiftUI view laid out on its own (panels that are not in the window).
    static func snapView<V: View>(_ view: V, _ size: CGSize, _ out: URL, _ name: String) {
        let host = NSHostingView(rootView: view.preferredColorScheme(.dark).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = host
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out.appendingPathComponent("\(name).png")) }
        }
        note("snapshot \(name)")
    }

    static weak var model: EditorModel?

    static func waitFor(_ seconds: Double, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !cond() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        if !cond(), let m = model { note("TIMEOUT: \(m.diagnostics)") }
    }

    static func snap(_ model: EditorModel, _ out: URL, _ name: String) {
        if let win = manualWindow ?? NSApp.windows.first(where: { $0.isVisible }), let v = win.contentView,
           let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
            v.cacheDisplay(in: v.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out.appendingPathComponent("\(name)-window.png")) }
        }
        if let cg = model.canvas.snapshot() {
            let url = out.appendingPathComponent("\(name)-canvas.png")
            if let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                // Convert to 8-bit sRGB for viewing.
                let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
                CGImageDestinationFinalize(d)
            }
        }
        note("snapshot \(name)")
    }
}
