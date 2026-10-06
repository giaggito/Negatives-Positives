import AppKit
import DarkroomUI
import PositivesCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct PositivesApp: App {
    @State private var model: EditorModel
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        let m = EditorModel()
        // `open -a Positives --args <folder or photos>` opens them directly.
        var args = Array(CommandLine.arguments.dropFirst())
        var selfTest: URL?
        if let i = args.firstIndex(of: "--self-test"), i + 1 < args.count {
            selfTest = URL(fileURLWithPath: args[i + 1])
            args.removeSubrange(i...(i + 1))
        }
        if selfTest != nil {
            // Start from unedited photos: forget archive entries of earlier runs — only for temporary folders.
            for e in Archive.shared.entries where e.path.hasPrefix("/private/tmp/") || e.path.hasPrefix("/tmp/") || e.path.hasPrefix(NSTemporaryDirectory()) {
                Archive.shared.remove(e.id)
            }
            m.archived = Archive.shared.entries
        }
        let paths = args.filter { $0.hasPrefix("/") }
        if !paths.isEmpty { DispatchQueue.main.async { m.open(paths.map { URL(fileURLWithPath: $0) }) } }
        if let selfTest { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { SelfTest.run(model: m, out: selfTest) } }
        _model = State(initialValue: m)
        AppDelegate.model = m
        KeyMonitor.install(model: m)
    }

    var body: some Scene {
        Window("Positives - photo editor", id: "main") {
            MainView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1000, minHeight: 660)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { PositivesCommands(model: model) }
        Window("Credits & Licences", id: "credits") {
            PositivesCredits().preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Asks before quitting when edits were not saved to the archive.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: EditorModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let m = Self.model, !SelfTest.running else { return .terminateNow }
        m.rememberCurrent()
        guard !m.unsaved.isEmpty else { return .terminateNow }
        let a = NSAlert()
        let n = m.unsaved.count
        a.messageText = n == 1 ? "Save your edit before quitting?" : "Save your edits to \(n) photos before quitting?"
        a.informativeText = "Saved photos appear on the start screen, so you can continue where you left off. If you don't save, the edits are discarded."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Don't Save")
        a.addButton(withTitle: "Cancel")
        switch a.runModal() {
        case .alertFirstButtonReturn: m.saveAllUnsaved(); return .terminateNow
        case .alertSecondButtonReturn: return .terminateNow
        default: return .terminateCancel
        }
    }
}

/// Hold-to-compare: the picture shows the "before" state for as long as \ is held down.
enum KeyMonitor {
    static func install(model: EditorModel) {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
            guard e.charactersIgnoringModifiers == "\\", e.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSText), model.hasPhoto else { return e }
            if e.type == .keyDown { if !e.isARepeat { model.showBefore = true } } else { model.showBefore = false }
            return nil
        }
    }
}

struct PositivesCommands: Commands {
    let model: EditorModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Credits & Licences") { openWindow(id: "credits") }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open…") { model.chooseAndOpen() }.keyboardShortcut("o")
            Button("Save to Archive") { model.saveToArchive() }.keyboardShortcut("s").disabled(!model.hasPhoto)
            Button("Start Screen") { model.goHome() }.keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Export…") { NotificationCenter.default.post(name: .showExport, object: nil) }.keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
            Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy Settings") { model.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Settings") { model.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Divider()
            Button("Reset All Adjustments") { model.resetAll() }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Photo") {
            Button("Crop & Straighten") { model.toggleTool(.crop) }.keyboardShortcut("c", modifiers: [])
            Button("White Balance Picker") { model.toggleTool(.whiteBalance) }.keyboardShortcut("w", modifiers: [])
            Button("Show Mask Overlay") { model.showMaskOverlay.toggle() }.keyboardShortcut("o", modifiers: [])
            Button("Presets…") { NotificationCenter.default.post(name: .showPresets, object: nil) }.keyboardShortcut("p", modifiers: [])
            Button("Save Settings as Preset…") { NotificationCenter.default.post(name: .savePreset, object: Preset.Scope.look) }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.hasPhoto)
            Divider()
            Button("Rotate Left") { model.rotate(clockwise: false) }.keyboardShortcut("[", modifiers: [])
            Button("Rotate Right") { model.rotate(clockwise: true) }.keyboardShortcut("]", modifiers: [])
            Button("Flip Horizontal") { model.flip(horizontal: true) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Flip Vertical") { model.flip(horizontal: false) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Previous Photo") { model.selectPrevious() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Photo") { model.selectNext() }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        CommandGroup(after: .toolbar) {
            Button("Zoom to Fit") { model.fit() }.keyboardShortcut("0")
            Button("Zoom 100%") { model.zoom(1) }.keyboardShortcut("1")
            Button("Zoom 200%") { model.zoom(2) }.keyboardShortcut("2")
            Button("Zoom In") { model.zoomIn() }.keyboardShortcut("+")
            Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-")
            Button("Fit ↔ 100%") { model.toggleZoom() }.keyboardShortcut("z", modifiers: [])
            Divider()
            Button("Clipping Warnings") { model.showClipping.toggle() }.keyboardShortcut("j", modifiers: [])
            Button("Histogram") { model.showHistogram.toggle() }.keyboardShortcut("h", modifiers: [.command, .option])
            Divider()
        }
    }
}

extension Notification.Name {
    static let showExport = Notification.Name("positives.showExport")
    static let showPresets = Notification.Name("positives.showPresets")
    static let savePreset = Notification.Name("positives.savePreset")
}

struct MainView: View {
    @Bindable var model: EditorModel
    @State private var showExport = false
    @State private var showPresets = false
    @State private var savePresetScope: Preset.Scope?
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                ZStack {
                    PhotoCanvas(controller: model.canvas, state: model.canvasState)
                        .opacity(model.hasPhoto ? 1 : 0)
                    if !model.hasPhoto && model.items.isEmpty { StartScreen(model: model) }
                    overlays
                }
                if model.tool == .crop && model.hasPhoto {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    CropBar(model: model)
                }
                if !model.items.isEmpty {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    Filmstrip(items: model.items.enumerated().map { i, item in
                        FilmstripItem(id: item.id, thumbnail: item.thumbnail, label: item.url.deletingPathExtension().lastPathComponent,
                                      help: item.url.lastPathComponent, badge: item.edited)
                    }, selection: model.selection, marked: model.marked) { i, mods in model.filmstripClicked(i, modifiers: mods) }
                }
            }
            if model.hasPhoto {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                Inspector(model: model, showExport: $showExport)
            }
        }
        .background(Theme.canvas)
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).stroke(Theme.accent.opacity(0.6), lineWidth: 2).padding(8) } }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { urls.append(u) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.open(urls) }
            return true
        }
        .sheet(isPresented: $showExport) { ExportSheet(model: model, isPresented: $showExport) }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { _ in if model.hasPhoto { showExport = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showPresets)) { _ in if model.hasPhoto { showPresets.toggle() } }
        .onReceive(NotificationCenter.default.publisher(for: .savePreset)) { n in
            if model.hasPhoto { savePresetScope = n.object as? Preset.Scope ?? .look }
        }
        .sheet(isPresented: Binding(get: { savePresetScope != nil }, set: { if !$0 { savePresetScope = nil } })) {
            SavePresetSheet(model: model, isPresented: Binding(get: { savePresetScope != nil }, set: { if !$0 { savePresetScope = nil } }),
                            scope: savePresetScope ?? .look)
        }
    }

    @ViewBuilder
    private var overlays: some View {
        if model.hasPhoto {
            if model.tool == .crop {
                CropOverlay(model: model)
            } else if model.category == .masks {
                MaskOverlay(model: model)
            } else if model.category == .layers {
                LayerOverlay(model: model)
                MaskOverlay(model: model)
            }
            VStack {
                HStack(alignment: .top) {
                    if model.showBefore { Chip("Before") }
                    Spacer()
                    if model.showHistogram && model.tool != .crop {
                        HistogramView(bins: model.histogram.bins, shadowClip: model.histogram.shadowClip,
                                      highlightClip: model.histogram.highlightClip, showsClipping: $model.showClipping)
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    if model.loadingFullQuality { StatusCapsule("Preparing full quality…") }
                    if let s = model.status { StatusCapsule(s) }
                    if let m = model.exportMessage { StatusCapsule(m, progress: model.exportProgress) }
                }
            }
            .padding(16)
            .allowsHitTesting(true)
        } else if let s = model.status {
            StatusCapsule(s)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Group {
                if model.hasPhoto || !model.items.isEmpty {
                    IconButton(symbol: "house", help: "Start screen (⇧⌘O)") { model.goHome() }
                }
            }
            .padding(.leading, 74)
            Text(model.current?.url.lastPathComponent ?? model.folder?.lastPathComponent ?? "")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .lineLimit(1)
            Spacer()
            if model.hasPhoto {
                Text(zoomLabel).font(Theme.value).foregroundStyle(Theme.tertiary).frame(width: 46, alignment: .trailing)
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit (⌘0)", active: model.canvasState.isFit) { model.fit() }
                IconButton(symbol: "1.magnifyingglass", help: "100% (⌘1, Z, or double-click)", active: abs(model.canvasState.magnification - 1) < 0.001) { model.zoom(1) }
                ToolbarDivider()
                IconButton(symbol: "crop", help: "Crop & straighten (C)", active: model.tool == .crop) { model.toggleTool(.crop) }
                IconButton(symbol: "rotate.left", help: "Rotate left ([)") { model.rotate(clockwise: false) }
                IconButton(symbol: "rotate.right", help: "Rotate right (])") { model.rotate(clockwise: true) }
                ToolbarDivider()
                IconButton(symbol: "square.split.2x1", help: "Before (hold \\)", active: model.showBefore) { model.showBefore.toggle() }
                IconButton(symbol: "exclamationmark.triangle", help: "Clipping warnings (J)", active: model.showClipping) { model.showClipping.toggle() }
                IconButton(symbol: "waveform.path.ecg", help: "Histogram (⌥⌘H)", active: model.showHistogram) { model.showHistogram.toggle() }
                ToolbarDivider()
                IconButton(symbol: "camera.filters", help: "Presets (P)", active: showPresets) { showPresets.toggle() }
                    .popover(isPresented: $showPresets, arrowEdge: .bottom) { PresetsPopover(model: model) }
                ToolbarDivider()
            }
            IconButton(symbol: "folder", help: "Open folder or photos (⌘O)") { model.chooseAndOpen() }
            if model.hasPhoto {
                ToolbarDivider()
                SaveButton(unsaved: model.currentIsUnsaved, archived: model.currentIsArchived) { model.saveToArchive() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.canvas)
    }

    private var zoomLabel: String {
        model.canvasState.isFit ? "Fit" : String(format: "%.0f%%", model.canvasState.magnification * 100)
    }
}

/// The save button: filled when the photo has changes that are not in the archive yet.
struct SaveButton: View {
    let unsaved: Bool
    let archived: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: unsaved ? "tray.and.arrow.down.fill" : (archived ? "checkmark" : "tray.and.arrow.down"))
                    .font(.system(size: 11, weight: .medium))
                Text(unsaved || !archived ? "Save" : "Saved").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(unsaved ? Color.black : (hover ? Theme.text : Theme.secondary))
            .padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(unsaved ? Theme.accent : (hover ? Theme.hairline : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(unsaved ? "Save this photo and its edits to the archive (⌘S) — find it on the start screen later"
                      : (archived ? "Saved in the archive" : "Save to the archive (⌘S)"))
    }
}

/// Start screen: open photos, or continue a photo saved to the archive.
struct StartScreen: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Positives").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.text)
                    Text("photo editor").font(.system(size: 13, weight: .light)).foregroundStyle(Theme.tertiary)
                }
                Text("Drop a folder or photos here — any camera RAW, JPEG, HEIC, PNG, TIFF").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                PlainTextButton(title: "Open…", symbol: "folder", prominent: true) { model.chooseAndOpen() }
                    .frame(width: 180)
            }
            .padding(.top, model.archived.isEmpty ? 0 : 48)
            .padding(.bottom, 28)
            if model.archived.isEmpty {
                Text("Photos you save (⌘S) will appear here, so you can continue where you left off.")
                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            } else {
                HStack {
                    Text("Saved photos").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                    Spacer()
                    Text("\(model.archived.count)").font(Theme.value).foregroundStyle(Theme.tertiary)
                }
                .padding(.horizontal, 32).padding(.bottom, 10)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)], spacing: 18) {
                        ForEach(model.archived) { e in ArchiveTile(entry: e, model: model) }
                    }
                    .padding(.horizontal, 32).padding(.bottom, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.archived.isEmpty ? .center : .top)
    }
}

private struct ArchiveTile: View {
    let entry: ArchiveEntry
    let model: EditorModel
    @State private var hover = false
    @State private var image: NSImage?

    var body: some View {
        Button { model.openArchived(entry) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Rectangle().fill(Theme.hairline)
                    if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(hover ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
                Text(entry.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(entry.saved.formatted(date: .abbreviated, time: .shortened) + (entry.edit.film.stock.flatMap { FilmLooks.shared.look($0)?.name }.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Continue editing \(entry.name)")
        .contextMenu {
            Button("Open") { model.openArchived(entry) }
            Button("Show Original in Finder") {
                if let u = Archive.shared.resolve(entry) { NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
            Divider()
            Button("Remove from Saved Photos") { model.removeFromArchive(entry) }
        }
        .task(id: entry.saved) { image = NSImage(contentsOf: Archive.shared.thumbnailURL(entry.id)) }
    }
}

/// Help → Credits & Licences.
struct PositivesCredits: View {
    var body: some View {
        CreditsView(app: "Positives - photo editor", credits: Credits.items, notice: Credits.trademarks, licenceText: Credits.licenceText)
    }
}
