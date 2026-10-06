import Foundation

public struct PhotoExportResult: Sendable {
    public var url: URL
    public var report: ExportReport
}

/// Full-quality export of one photo: full-resolution decode, the exact render (identical to the exact
/// preview), resizing and output sharpening (`OutputFinish`), then the exporter (the only place values are
/// quantised).
public enum PhotoExport {
    public static func export(photo: URL, edit: EditState?, options: ExportOptions, to folder: URL, engine: RenderEngine,
                              source preloaded: SourceImage? = nil, output: OutputSettings = OutputSettings()) throws -> PhotoExportResult {
        let source = try preloaded.flatMap { $0.isProxy ? nil : $0 } ?? SourceLoader.load(url: photo)
        try engine.setSource(source)
        let e = edit ?? .initial(for: source)
        let full = try engine.renderFull(e)
        var grainFree: LinearImage?
        if output.sharpening != .none, e.effective.grain.isActive {
            // Sharpen the picture, not the grain (see OutputFinish).
            var clean = e
            clean.grain.amount = 0
            grainFree = try engine.renderFull(clean)
        }
        let image = OutputFinish.apply(full, output, grainFree: grainFree)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let out = uniqueURL(folder.appendingPathComponent(photo.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(options.format.fileExtension))
        let report = try Exporter.write(image, to: out, options: options, metadataSource: photo, software: "Positives")
        return PhotoExportResult(url: out, report: report)
    }

    /// Never overwrite: name.jpg, name-2.jpg, name-3.jpg …
    static func uniqueURL(_ url: URL) -> URL {
        var u = url
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(n).\(url.pathExtension)")
            n += 1
        }
        return u
    }
}
