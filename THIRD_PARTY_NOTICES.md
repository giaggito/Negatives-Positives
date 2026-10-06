# Third-party notices

Negatives and Positives are © 2026 Giacomo Ancora and licensed under the GNU General Public License, version 3
(see `LICENSE`). They build on the following work, each under its own licence. The full licence texts ship
inside both apps (Help → Credits & Licences) and are in this repository at the paths given.

## Both apps

| Work | Used for | Licence | Licence text |
|---|---|---|---|
| [LibRaw](https://www.libraw.org) 0.22.2 (LibRaw LLC; based on dcraw by Dave Coffin) | reading RAW files | LGPL-2.1 (dual-licensed LGPL-2.1 / CDDL-1.0; used here under the LGPL). Included unmodified, with its source, in `Packages/DarkroomKit/Vendor/LibRaw` | `Packages/DarkroomKit/Sources/DarkroomCore/Resources/LIBRAW_LICENSE.txt` |
| [libjpeg-turbo](https://libjpeg-turbo.org) (linked statically). This software is based in part on the work of the Independent JPEG Group. | reading and writing JPEG files | IJG, BSD-3-Clause, zlib | `Packages/DarkroomKit/Sources/DarkroomCore/Resources/LIBJPEG_TURBO_LICENSE.txt` |
| [LLVM OpenMP runtime](https://openmp.llvm.org) (libomp, linked statically) | multi-core RAW decoding | Apache-2.0 with LLVM exceptions | `Packages/DarkroomKit/Sources/DarkroomCore/Resources/LIBOMP_LICENSE.txt` |

## Positives

| Work | Used for | Licence | Licence text |
|---|---|---|---|
| [RawTherapee Film Simulation Collection](https://rawpedia.rawtherapee.com/Film_Simulation) (Pat David, Pavlov Dmitry, Michael Ezra) | colour tables of most film looks (adapted; the adapted tables stay CC BY-SA 4.0) | CC BY-SA 4.0 | `Sources/PositivesCore/Resources/FILM_LOOKS_LICENSE.txt` |
| [t3mujinpack](https://github.com/t3mujinpack/t3mujinpack) (João Almeida) | Kodak Gold 200, UltraMax 400 and ColorPlus 200 looks (adapted) | MIT | `Sources/PositivesCore/Resources/FILM_LOOKS_LICENSE.txt` |
| [spektrafilm](https://github.com/andreavolpato/spektrafilm) (Andrea Volpato) | spectral film data (`FilmData.json`; also used by the Negatives test bench) | CC BY-SA 4.0 | `Sources/PositivesCore/Resources/FILM_DATA_LICENSE.txt`, changes in `FILM_DATA_CHANGELOG.txt` |
| [Sky segmentation, U²-Net](https://github.com/xiongzhu666/Sky-Segmentation-and-Post-processing) (xiongzhu666) | the Sky mask (converted to Core ML) | MIT | `Sources/PositivesCore/Resources/SKY_MODEL_LICENSE.txt` |
| [Realistic Film Grain Rendering](https://www.ipol.im/pub/art/2017/192/) (Newson, Delon, Galerne, IPOL 2017) | the method behind the film grain (reimplemented from the paper; no code copied) | — | — |

## Trademarks

Film and brand names (Kodak, Fujifilm, Ilford, Agfa, Polaroid, CineStill and their film names) are trademarks of
their owners. They are used only to say which film a look approximates; Negatives and Positives are not
affiliated with or endorsed by them.
