import Foundation

/// A piece of work an app builds on, with its authors and licence (shown in the Credits & Licences window).
public struct Credit: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let what: String
    public let authors: String
    public let licence: String
    public let link: String
    /// Licence file (without ".txt") in the app's resources, if any.
    public let file: String?

    public init(name: String, what: String, authors: String, licence: String, link: String, file: String?) {
        (self.name, self.what, self.authors, self.licence, self.link, self.file) = (name, what, authors, licence, link, file)
    }
}

/// The apps' own licence and the libraries both apps are built with.
public enum SharedCredits {
    public static let copyright = "© 2026 Giacomo Ancora"
    /// File of the apps' own licence (GNU GPL version 3).
    public static let appLicenceFile = "GPL-3.0"
    /// Where people can support the apps (Help menu, Credits window).
    public static let supportURL = URL(string: "https://buymeacoffee.com/ancoragiacg")!
    /// The apps' website (downloads and install help).
    public static let websiteURL = URL(string: "https://giaggito.github.io/Negatives-Positives/")!

    public static let libraries: [Credit] = [
        Credit(name: "LibRaw", what: "Reading RAW files", authors: "LibRaw LLC; based on dcraw by Dave Coffin",
               licence: "LGPL 2.1", link: "https://www.libraw.org", file: "LIBRAW_LICENSE"),
        Credit(name: "libjpeg-turbo", what: "Reading and writing JPEG files. This software is based in part on the work of the Independent JPEG Group.",
               authors: "The libjpeg-turbo Project, the Independent JPEG Group", licence: "IJG / BSD-3-Clause / zlib",
               link: "https://libjpeg-turbo.org", file: "LIBJPEG_TURBO_LICENSE"),
        Credit(name: "LLVM OpenMP runtime", what: "Decoding RAW files on all processor cores", authors: "The LLVM Project",
               licence: "Apache 2.0 with LLVM exceptions", link: "https://openmp.llvm.org", file: "LIBOMP_LICENSE"),
    ]

    /// Full text of a licence file bundled with the shared code.
    public static func licenceText(_ file: String) -> String? {
        Bundle.module.url(forResource: file, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }
}
