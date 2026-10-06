import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo saved to the archive: where the original is, its edit and when it was saved.
public struct ArchiveEntry: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Last known location of the original photo.
    public var path: String
    /// Finds the photo again if it is moved or renamed (macOS bookmark).
    public var bookmark: Data?
    public var edit: EditState
    public var saved: Date

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { url.lastPathComponent }
}

/// The archive of saved edits ("Save" in the editor; listed on the start screen). It lives in the app's own
/// data folder — ~/Library/Application Support/Positives/Archive — never next to the photos: an index
/// (archive.json) and one small JPEG thumbnail per photo. Originals are never touched.
public final class Archive: @unchecked Sendable {
    public static let shared = Archive(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Positives/Archive", isDirectory: true))

    public let directory: URL
    public private(set) var entries: [ArchiveEntry] = []
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        if let d = try? Data(contentsOf: indexURL) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            entries = (try? dec.decode([ArchiveEntry].self, from: d)) ?? []
        }
    }

    private var indexURL: URL { directory.appendingPathComponent("archive.json") }
    public func thumbnailURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).jpg") }

    /// The entry of a photo, by location (resolving moved files through their bookmarks).
    public func entry(for url: URL) -> ArchiveEntry? {
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.path == path }
    }

    /// Where the original is now (follows moves and renames), nil if it is gone.
    public func resolve(_ e: ArchiveEntry) -> URL? {
        if FileManager.default.fileExists(atPath: e.path) { return e.url }
        guard let b = e.bookmark else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: b, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: u.path) else { return nil }
        update(e.id) { $0.path = u.standardizedFileURL.path; if stale { $0.bookmark = try? u.bookmarkData() } }
        return u
    }

    /// Saves (or updates) a photo's edit and thumbnail.
    @discardableResult
    public func save(_ edit: EditState, for url: URL, thumbnail: CGImage?) throws -> ArchiveEntry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = url.standardizedFileURL.path
        lock.lock()
        var e = entries.first { $0.path == path } ?? ArchiveEntry(id: UUID(), path: path, bookmark: nil, edit: edit, saved: Date())
        e.edit = edit
        e.saved = Date()
        e.bookmark = (try? url.bookmarkData()) ?? e.bookmark
        entries.removeAll { $0.id == e.id }
        entries.insert(e, at: 0)
        lock.unlock()
        if let thumbnail { Self.writeJPEG(thumbnail, to: thumbnailURL(e.id)) }
        try writeIndex()
        return e
    }

    public func remove(_ id: UUID) {
        lock.lock()
        entries.removeAll { $0.id == id }
        lock.unlock()
        try? FileManager.default.removeItem(at: thumbnailURL(id))
        try? writeIndex()
    }

    private func update(_ id: UUID, _ body: (inout ArchiveEntry) -> Void) {
        lock.lock()
        if let i = entries.firstIndex(where: { $0.id == id }) { body(&entries[i]) }
        lock.unlock()
        try? writeIndex()
    }

    private func writeIndex() throws {
        lock.lock()
        let list = entries
        lock.unlock()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(list).write(to: indexURL, options: .atomic)
    }

    static func writeJPEG(_ image: CGImage, to url: URL) {
        // 8-bit sRGB for a small, portable thumbnail.
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let img = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(d)
    }
}
