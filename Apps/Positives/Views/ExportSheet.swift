import DarkroomUI
import PositivesCore
import SwiftUI

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Binding var isPresented: Bool
    @AppStorage("p.export.format") private var formatRaw = ExportFormat.jpeg.rawValue
    @AppStorage("p.export.space") private var spaceRaw = OutputColorSpace.sRGB.rawValue
    @AppStorage("p.export.quality") private var quality = 95.0
    @AppStorage("p.export.chroma444") private var chroma444 = true
    @AppStorage("p.export.lzw") private var lzw = false
    @AppStorage("p.export.metadata") private var metadata = true
    @AppStorage("p.export.size") private var sizeRaw = OutputSettings.Size.full.rawValue
    @AppStorage("p.export.longEdge") private var longEdge = 2048
    @AppStorage("p.export.printCM") private var printCM = 30.0
    @AppStorage("p.export.dpi") private var dpi = 300.0
    @AppStorage("p.export.sharpen") private var sharpenRaw = OutputSettings.Sharpening.none.rawValue
    @AppStorage("p.export.strength") private var strength = 1
    @State private var scope = 0
    @State private var destination: URL?

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .jpeg }
    private var space: OutputColorSpace { OutputColorSpace(rawValue: spaceRaw) ?? .sRGB }
    private var output: OutputSettings {
        var o = OutputSettings()
        o.size = OutputSettings.Size(rawValue: sizeRaw) ?? .full
        o.longEdge = longEdge
        o.printLongCM = printCM
        o.dpi = dpi
        o.sharpening = OutputSettings.Sharpening(rawValue: sharpenRaw) ?? .none
        o.strength = strength
        return o
    }
    private var target: URL? { destination ?? model.folder?.appendingPathComponent("Exports") }
    private var chosen: [PhotoItem] {
        switch scope {
        case 1: return model.marked.sorted().map { model.items[$0] }
        case 2: return model.items
        default: return [model.current].compactMap { $0 }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            row("Photos") {
                Segmented(options: model.marked.count > 1 ? ["This photo", "Selected (\(model.marked.count))", "All (\(model.items.count))"]
                                                          : ["This photo", "All (\(model.items.count))"],
                          selection: Binding(get: { model.marked.count > 1 ? scope : (scope == 2 ? 1 : 0) },
                                             set: { scope = model.marked.count > 1 ? $0 : ($0 == 1 ? 2 : 0) }))
            }
            row("Format") {
                Picker("", selection: $formatRaw) {
                    ForEach([ExportFormat.jpeg, .tiff16, .tiff32, .heic], id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }.labelsHidden()
            }
            if format == .jpeg || format == .heic {
                row("Quality") {
                    ParameterSlider(title: "", value: $quality, range: 60...100, defaultValue: 95, format: { String(format: "%.0f", $0) })
                }
            }
            if format == .jpeg {
                row("Colour detail") {
                    Segmented(options: ["Full (4:4:4)", "Half (4:2:0)"], selection: Binding(get: { chroma444 ? 0 : 1 }, set: { chroma444 = $0 == 0 }))
                }
            }
            if format == .tiff16 || format == .tiff32 {
                row("Compression") {
                    Segmented(options: ["None", "LZW (lossless)"], selection: Binding(get: { lzw ? 1 : 0 }, set: { lzw = $0 == 1 }))
                }
            }
            row("Size") {
                Segmented(options: ["Full", "Long edge", "Print"], selection: Binding(
                    get: { OutputSettings.Size.allCases.firstIndex(of: output.size) ?? 0 },
                    set: { sizeRaw = OutputSettings.Size.allCases[$0].rawValue }))
            }
            if output.size == .longEdge {
                row("") {
                    HStack(spacing: 8) {
                        TextField("", value: $longEdge, format: .number).textFieldStyle(.roundedBorder).frame(width: 80)
                        Text("pixels").font(Theme.label).foregroundStyle(Theme.tertiary)
                        Spacer()
                        ForEach([1080, 2048, 4096], id: \.self) { n in
                            PlainTextButton(title: "\(n)") { longEdge = n }
                        }
                    }
                }
            }
            if output.size == .print {
                row("") {
                    HStack(spacing: 8) {
                        TextField("", value: $printCM, format: .number.precision(.fractionLength(0...1))).textFieldStyle(.roundedBorder).frame(width: 56)
                        Text("cm long side at").font(Theme.label).foregroundStyle(Theme.tertiary)
                        TextField("", value: $dpi, format: .number.precision(.fractionLength(0))).textFieldStyle(.roundedBorder).frame(width: 56)
                        Text("dpi").font(Theme.label).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            row("Sharpen for") {
                HStack(spacing: 8) {
                    Picker("", selection: $sharpenRaw) {
                        ForEach(OutputSettings.Sharpening.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().fixedSize()
                    if output.sharpening != .none {
                        Segmented(options: ["Low", "Standard", "High"], selection: $strength)
                    }
                }
            }
            row("Colour space") {
                Picker("", selection: $spaceRaw) {
                    ForEach(OutputColorSpace.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }.labelsHidden()
            }
            row("Metadata") {
                Toggle("Keep camera data (EXIF, date, GPS)", isOn: $metadata).toggleStyle(.checkbox).font(Theme.label)
            }
            row("Destination") {
                HStack {
                    Text(target?.path(percentEncoded: false).replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "—")
                        .font(Theme.value).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    PlainTextButton(title: "Change…") {
                        let p = NSOpenPanel()
                        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                        p.directoryURL = model.folder
                        if p.runModal() == .OK { destination = p.url }
                    }
                }
            }
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                PlainTextButton(title: "Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                PlainTextButton(title: "Export", prominent: true) {
                    guard let t = target else { return }
                    let o = ExportOptions(format: format, space: space, quality: Int(quality), chroma444: chroma444,
                                          tiffCompression: lzw ? .lzw : .none, includeMetadata: metadata, dpi: output.size == .print ? dpi : 300)
                    model.histogramSpace = space
                    model.export(items: chosen, options: o, output: output, to: t)
                    isPresented = false
                }
                .frame(width: 110)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var note: String {
        let size = model.displaySize
        let px = output.pixelSize(width: Int(size.width), height: Int(size.height))
        var res: String
        switch output.size {
        case .full: res = "Full resolution (\(px.width)×\(px.height)), exactly as the preview shows at 100%."
        case .longEdge, .print:
            let up = max(px.width, px.height) > Int(max(size.width, size.height))
            res = "\(px.width)×\(px.height) pixels" + (output.size == .print ? String(format: " (%.1f×%.1f cm at %.0f dpi)", Double(px.width) / dpi * 2.54, Double(px.height) / dpi * 2.54, dpi) : "")
                + (up ? ", enlarged from \(Int(size.width))×\(Int(size.height)) with Lanczos resampling." : ", resampled in linear light (Lanczos).")
        }
        if output.sharpening != .none { res += " Sharpened for \(output.sharpening.title.lowercased())." }
        switch format {
        case .jpeg: return res + " 8-bit, dithered so gradients never band."
        case .tiff16: return res + " 16 bits per channel, for printing or further editing."
        case .tiff32: return res + " 32-bit floating point, linear light, nothing clipped."
        case .heic: return res + " 10-bit HEIC: smaller than JPEG with more tonal steps."
        case .png8: return res
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary).frame(width: 96, alignment: .leading)
            content()
        }
    }
}
