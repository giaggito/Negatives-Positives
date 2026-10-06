import DarkroomUI
import NegativesCore
import SwiftUI

struct RollFilmstrip: View {
    @Bindable var model: RollModel

    var body: some View {
        Filmstrip(items: model.frames.enumerated().map { i, f in
            FilmstripItem(id: f.id, thumbnail: f.thumbnail, label: "\(i + 1)", help: f.url.lastPathComponent)
        }, selection: model.selection) { i, _ in model.select(i) }
    }
}

struct ExportSheet: View {
    @Bindable var model: RollModel
    @Binding var isPresented: Bool
    @AppStorage("export.format") private var formatRaw = ExportFormat.tiff16.rawValue
    @AppStorage("export.space") private var spaceRaw = OutputColorSpace.proPhoto.rawValue
    @AppStorage("export.all") private var all = false
    @State private var destination: URL?

    private var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .tiff16 }
    private var space: OutputColorSpace { OutputColorSpace(rawValue: spaceRaw) ?? .proPhoto }
    private var target: URL? { destination ?? model.folder?.appendingPathComponent("Positives") }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)

            row("Frames") {
                Segmented(options: ["This frame", "Whole roll (\(model.frames.count))"], selection: Binding(get: { all ? 1 : 0 }, set: { all = $0 == 1 }))
            }
            row("Format") {
                Picker("", selection: $formatRaw) {
                    Text("TIFF 16-bit").tag(ExportFormat.tiff16.rawValue)
                    Text("TIFF 32-bit float (linear)").tag(ExportFormat.tiff32.rawValue)
                    Text("JPEG (for sharing)").tag(ExportFormat.jpeg.rawValue)
                }.labelsHidden()
            }
            row("Colour space") {
                Picker("", selection: $spaceRaw) {
                    ForEach(OutputColorSpace.allCases, id: \.rawValue) { Text($0.displayName).tag($0.rawValue) }
                }.labelsHidden()
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
                    let frames = all ? model.frames : [model.current].compactMap { $0 }
                    model.export(frames: frames, to: t, format: format, space: space)
                    isPresented = false
                }
                .frame(width: 110)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
    }

    private var note: String {
        switch format {
        case .tiff16: return "Uncompressed 16-bit TIFF with embedded ICC profile. ProPhoto RGB keeps every colour the film recorded."
        case .tiff32: return "Uncompressed 32-bit floating point, linear light, nothing clipped. For further grading in other software."
        case .jpeg: return "High-quality JPEG with embedded profile, for sharing. Use sRGB for the web."
        case .heic, .png8: return ""
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary).frame(width: 90, alignment: .leading)
            content()
        }
    }
}
