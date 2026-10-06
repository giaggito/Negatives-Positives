import DarkroomCore
import DarkroomUI
import NegativesCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct NegativesApp: App {
    @State private var model: RollModel

    init() {
        let m = RollModel()
        // `open -a Negatives --args <folder or RAFs>` opens a roll directly.
        let paths = CommandLine.arguments.dropFirst().filter { $0.hasPrefix("/") }
        if !paths.isEmpty { m.open(paths.map { URL(fileURLWithPath: $0) }) }
        _model = State(initialValue: m)
    }

    var body: some Scene {
        Window("Negatives", id: "main") {
            MainView(model: model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveNow() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands { NegativesCommands(model: model) }
        Window("Credits & Licences", id: "credits") {
            CreditsView(app: "Negatives", credits: SharedCredits.libraries).preferredColorScheme(.dark)
        }
        .windowResizability(.contentMinSize)
    }
}

struct NegativesCommands: Commands {
    let model: RollModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Credits & Licences") { openWindow(id: "credits") }
            Divider()
            Button("Buy Me a Coffee…") { NSWorkspace.shared.open(SharedCredits.supportURL) }
            Button("Website") { NSWorkspace.shared.open(SharedCredits.websiteURL) }
        }
        CommandGroup(replacing: .newItem) {
            Button("Open Roll…") { model.chooseAndOpen() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Copy Settings") { model.copySettings() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Paste Settings") { model.pasteSettings() }.keyboardShortcut("v", modifiers: [.command, .shift])
            Button("Paste Settings to Whole Roll") { model.pasteSettings(toAll: true) }.keyboardShortcut("v", modifiers: [.command, .shift, .option])
            Divider()
            Button("Reset Look") { model.resetLook() }.keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Image") {
            Button("Rotate Left") { model.rotate(clockwise: false) }.keyboardShortcut("[", modifiers: [])
            Button("Rotate Right") { model.rotate(clockwise: true) }.keyboardShortcut("]", modifiers: [])
            Button("Flip Horizontal") { model.flip(horizontal: true) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Flip Vertical") { model.flip(horizontal: false) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Crop & Straighten") { model.tool = model.tool == .crop ? .none : .crop }.keyboardShortcut("c", modifiers: [])
            Button("Measure Film Base") { model.tool = model.tool == .filmBase ? .none : .filmBase }.keyboardShortcut("b", modifiers: [])
            Button("Pick Neutral") { model.tool = model.tool == .whiteBalance ? .none : .whiteBalance }.keyboardShortcut("w", modifiers: [])
            Divider()
            Button("Before / After") { model.showBefore.toggle() }.keyboardShortcut("\\", modifiers: [])
            Button("Zoom 100%") { model.toggleZoom() }.keyboardShortcut("z", modifiers: [])
            Button("Histogram") { model.showHistogram.toggle() }.keyboardShortcut("h", modifiers: [.command, .option])
            Divider()
            Button("Previous Frame") { model.selectPrevious() }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Frame") { model.selectNext() }.keyboardShortcut(.rightArrow, modifiers: [])
        }
    }
}

struct MainView: View {
    @Bindable var model: RollModel
    @State private var showExport = false
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                ZStack(alignment: .topTrailing) {
                    ImageCanvas(model: model)
                    if model.showHistogram && model.displayImage != nil && !model.showBefore {
                        HistogramView(bins: model.histogram).padding(16)
                    }
                }
                if model.hasRoll {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    RollFilmstrip(model: model)
                }
            }
            if model.hasRoll {
                Rectangle().fill(Theme.hairline).frame(width: 1)
                Inspector(model: model, showExport: $showExport)
            }
        }
        .background(Theme.canvas)
        .overlay(alignment: .bottom) { exportStatus }
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
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Text(model.folder?.lastPathComponent ?? "")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                .padding(.leading, 78)  // clear the window buttons
            Spacer()
            if model.hasRoll {
                IconButton(symbol: "crop", help: "Crop & straighten (C)", active: model.tool == .crop) { model.tool = model.tool == .crop ? .none : .crop }
                IconButton(symbol: "rotate.left", help: "Rotate left ([)") { model.rotate(clockwise: false) }
                IconButton(symbol: "rotate.right", help: "Rotate right (])") { model.rotate(clockwise: true) }
                divider
                IconButton(symbol: "square.split.2x1", help: "Before / after (\\)", active: model.showBefore) { model.showBefore.toggle() }
                IconButton(symbol: "1.magnifyingglass", help: "Zoom 100% (Z, or double-click)", active: model.zoomCentre != nil) { model.toggleZoom() }
                IconButton(symbol: "waveform.path.ecg", help: "Histogram", active: model.showHistogram) { model.showHistogram.toggle() }
                divider
            }
            IconButton(symbol: "folder", help: "Open roll (⌘O)") { model.chooseAndOpen() }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Theme.canvas)
    }

    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 16).padding(.horizontal, 6) }

    @ViewBuilder
    private var exportStatus: some View {
        if let m = model.exportMessage {
            HStack(spacing: 10) {
                if let p = model.exportProgress {
                    ProgressView(value: p).progressViewStyle(.linear).frame(width: 120).tint(Theme.accent)
                }
                Text(m).font(Theme.label).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(Theme.panel))
            .overlay(Capsule().stroke(Theme.hairline))
            .padding(.bottom, model.hasRoll ? 124 : 24)
            .transition(.opacity)
        }
    }
}
