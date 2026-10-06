import Foundation

/// Which files make a roll: every RAW format LibRaw reads, plus JPEG / TIFF / HEIC / PNG scans. When a camera
/// wrote RAW + JPEG pairs, only the RAW is used (it holds the film's full density range).
public enum ScanFiles {
    public static func collect(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                files += items.filter(ImageLoader.isSupported)
            } else if ImageLoader.isSupported(u) {
                files.append(u)
            }
        }
        let rawStems = Set(files.filter(ImageLoader.isRaw).map { $0.deletingPathExtension().path })
        files.removeAll { !ImageLoader.isRaw($0) && rawStems.contains($0.deletingPathExtension().path) }
        return Array(Set(files)).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// File types the open panel offers.
    public static var extensions: [String] { Array(ImageLoader.rawExtensions) + Array(ImageLoader.imageExtensions) }
}
