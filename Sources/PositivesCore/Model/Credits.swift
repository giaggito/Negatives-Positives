import DarkroomCore
import Foundation

/// The work Positives builds on, with authors and licences (shown in the app's Credits window).
public enum Credits {
    public static let items: [Credit] = [
        Credit(name: "RawTherapee Film Simulation Collection", what: "Colour tables of most film looks (adapted)",
             authors: "Pat David, Pavlov Dmitry, Michael Ezra", licence: "CC BY-SA 4.0",
             link: "https://rawpedia.rawtherapee.com/Film_Simulation", file: "FILM_LOOKS_LICENSE"),
        Credit(name: "t3mujinpack", what: "Kodak Gold 200, UltraMax 400 and ColorPlus 200 looks (adapted)",
             authors: "João Almeida", licence: "MIT", link: "https://github.com/t3mujinpack/t3mujinpack", file: "FILM_LOOKS_LICENSE"),
        Credit(name: "spektrafilm", what: "Spectral data of the cinema films behind CineStill 800T and 50D",
             authors: "Andrea Volpato", licence: "CC BY-SA 4.0", link: "https://github.com/andreavolpato/spektrafilm", file: "FILM_DATA_LICENSE"),
        Credit(name: "Sky segmentation (U²-Net)", what: "The neural network behind the Sky mask",
             authors: "xiongzhu666", licence: "MIT", link: "https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing",
             file: "SKY_MODEL_LICENSE"),
        Credit(name: "Realistic Film Grain Rendering", what: "The method behind the film grain",
             authors: "Alasdair Newson, Julie Delon, Bruno Galerne (IPOL 2017)", licence: "Paper — method reimplemented",
             link: "https://www.ipol.im/pub/art/2017/192/", file: nil),
    ] + SharedCredits.libraries

    public static let trademarks = "Film and brand names (Kodak, Fujifilm, Ilford, Agfa, Polaroid, CineStill and their film names) are trademarks of their owners. They are used only to say which film a look approximates; Positives is not affiliated with or endorsed by them."

    /// Full text of a bundled licence file (Positives' own, or one shared with Negatives).
    public static func licenceText(_ file: String) -> String? {
        Bundle.module.url(forResource: file, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? SharedCredits.licenceText(file)
    }
}
