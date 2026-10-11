# FontPatcher Attribution and Licensing

This document consolidates the licensing information for the vendored
`FontPatcher/` tree (Nerd Fonts `font-patcher` script plus its glyph-set
sources). It supersedes any blanket license claim made elsewhere in this
repository, including `FONT_MANIFEST.md`.

Provenance of the vendored tree is documented in `FontPatcher/readme.md`:
an archive extracted from the Nerd Fonts project at version **3.4.0**
(commit `dc4e3309d6c1483532ccaefafd1e940d7c80dec1`, 2025-04-24).

Every entry below was verified against the license files that ship inside
this vendored tree (`FontPatcher/LICENSE`, `FontPatcher/src/glyphs/*/LICENSE*`,
`OFL*`). Two of those files were missing from the original archive and were
added verbatim from the upstream repositories at pinned revisions — see
"License verification record" below. Where a component's license is **not**
stated in the bundled files, that is called out explicitly rather than
guessed (currently: none).

## Component license table

| Component | Path | License (verified from bundled file) | License file | Version (per README) | Upstream |
|-----------|------|--------------------------------------|--------------|----------------------|----------|
| font-patcher script + name parser | `FontPatcher/font-patcher`, `FontPatcher/bin/scripts/name_parser/` | MIT (Copyright (c) 2014 Ryan L McIntyre) — Nerd Fonts original source code | `LICENSE` (upstream, added verbatim) | Nerd Fonts 3.4.0, script_version 4.20.3 | <https://github.com/ryanoasis/nerd-fonts/> |
| glyph-set database | `FontPatcher/glyphnames.json` | MIT (Copyright (c) 2014 Ryan L McIntyre) — Nerd Fonts source file outside any folder with its own license | `LICENSE` (upstream, added verbatim) | Nerd Fonts 3.4.0 | <https://github.com/ryanoasis/nerd-fonts/> |
| codicons | `FontPatcher/src/glyphs/codicons/` | CC-BY-4.0 (Creative Commons Attribution 4.0 International) | `LICENSE.txt` | 0.0.35 | <https://github.com/microsoft/vscode-codicons> |
| devicons | `FontPatcher/src/glyphs/devicons/` | MIT (Copyright (c) 2015 konpa) | `LICENSE` (upstream devicon v2.16.0, added verbatim) | 2.16.0.custom | <https://github.com/devicons/devicon> |
| Font Awesome | `FontPatcher/src/glyphs/font-awesome/` | CC-BY-4.0 (icons), SIL OFL 1.1 (fonts; Reserved Font Name "Font Awesome"), MIT (code) | `LICENSE.txt` | 6.5.1.custom | <https://github.com/FortAwesome/Font-Awesome> |
| Material Design Icons | `FontPatcher/src/glyphs/materialdesign/` | Pictogrammers Free License: Apache 2.0 (icons and fonts), MIT (code) | `LICENSE` | Last fetched 2022-10-06 | <https://github.com/Templarian/MaterialDesign-Font> |
| Octicons | `FontPatcher/src/glyphs/octicons/` | MIT (Copyright (c) 2023 GitHub Inc.) | `LICENSE` | — (no README in bundled dir) | <https://github.com/primer/octicons> (not named in the bundled files; MIT confirmed upstream) |
| Pomicons | `FontPatcher/src/glyphs/pomicons/` | SIL OFL 1.1 (Reserved Font Name "Pomicons") | `LICENSE` | 1.001 | <https://github.com/gabrielelana/pomicons> |
| Powerline Extra Symbols | `FontPatcher/src/glyphs/powerline-extra/` | MIT (Copyright (c) 2016 Ryan L McIntyre) | `LICENSE` | 1.200 (Nerd Fonts-modified) | <https://github.com/ryanoasis/powerline-extra-symbols> |
| Powerline Symbols | `FontPatcher/src/glyphs/powerline-symbols/` | MIT-style notice (Copyright 2013 Kim Silkebækken and other contributors) | `LICENSE.txt` | 1.000 (from about 2013) | <https://github.com/powerline/powerline> (stated in license text) |
| Weather Icons | `FontPatcher/src/glyphs/weather-icons/` | SIL OFL 1.1 (OFL.txt is the license template with placeholder copyright fields) | `OFL.txt`, `OFL-FAQ.txt` | — (no README in bundled dir) | <https://github.com/erikflowers/weather-icons> (not named in the bundled files; upstream README: icons SIL OFL 1.1) |
| extra glyph source | `FontPatcher/src/glyphs/extraglyphs.sfd` | MIT (Copyright (c) 2014 Ryan L McIntyre) — Nerd Fonts source file outside any folder with its own license | `LICENSE` (upstream, added verbatim) | — | <https://github.com/ryanoasis/nerd-fonts/> |

## License verification record

The original archive shipped no license for the `font-patcher` script (and
the other Nerd Fonts source files) and none for devicons. Both were resolved
against the upstream repositories on 2026-10-10 (re-audit "leave nothing
unfixed") and the upstream files were added verbatim, unmodified:

| Added file | Source (pinned) | SHA-256 |
|------------|-----------------|---------|
| `FontPatcher/LICENSE` | `ryanoasis/nerd-fonts` `LICENSE` at `dc4e3309d6c1483532ccaefafd1e940d7c80dec1` (the vendored 3.4.0 commit) | `1f6ad4edae6479aaace3112ede5279a23284ae54b2a34db66357aef5f64df160` |
| `FontPatcher/src/glyphs/devicons/LICENSE` | `devicons/devicon` `LICENSE` at tag `v2.16.0` (`6910f0503efdd315c8f9b858234310c06e04d9c0`) | `121194741d4a915b9f5890fdd6dd95121f9b1f816517c792358d72d7c838d664` |

The Nerd Fonts `LICENSE` states that original source code files (such as
`font-patcher` and `.sh`/`.py` files) and source files not in a folder with
an explicit license are MIT, and that fonts, glyph fonts and folders with an
explicit OFL file are SIL OFL 1.1. The upstream `license-audit.md` at the
same commit lists Devicons as MIT; the devicon repository's own `LICENSE` at
`v2.16.0` (MIT, Copyright (c) 2015 konpa) is the operative notice.

`FontPatcher/src/glyphs/README.md` also documents that the "Seti and
Original" icons live in `original-source.otf`, generated from
`src/svgs/`; neither file is present in this vendored archive.

## Local modifications recorded by the vendored tree

The bundled README files document Nerd Fonts' own modifications; keep these
attributions when redistributing (CC-BY-4.0 requires indicating changes):

- **codicons**: glyphs `0xEB40` and `0xEB41` fixed manually (upstream
  defect).
- **font-awesome**: the custom `FontAwesome.otf` is a subset built from the
  Font Awesome 6.5.1 release SVGs and does NOT contain all upstream icons.
- **materialdesign**: glyph `0xF1522` fixed manually (upstream defect,
  Templarian/MaterialDesign-Font issue #9).
- **powerline-extra**: additional glyphs (`0xE0CA` mirrored, `0x2630`,
  inverse triangular `0xE0D6`/`0xE0D7`, "landing platform" variants) and
  7% straight-side strips on `0xE0B4`/`0xE0B6`; version bumped to 1.200.
- **powerline-symbols**: `0xE0B0` and `0xE0B2` received a 7% straight-side
  strip.

## Redistribution requirements summary

The requirements below summarize the license texts shipped in this tree;
the license files themselves are authoritative and must accompany any
redistribution of the affected components.

### MIT-licensed sets (Octicons, Powerline Extra, Powerline Symbols)

- Retain the copyright notice and the MIT permission text with copies.
- The names of the copyright holders may not be used to endorse or promote
  derivatives.

### CC-BY-4.0 sets (codicons; Font Awesome icons)

- Attribution is required: credit the copyright holders, link to the
  license, and indicate any changes made.
- Do not imply endorsement.

### SIL OFL 1.1 sets (Pomicons; Font Awesome fonts; Weather Icons)

- Fonts (original or modified) may be bundled, embedded, redistributed, and
  sold **with software**, but never sold by themselves.
- Derivatives must remain entirely under the OFL and must not use the
  Reserved Font Names ("Pomicons", "Font Awesome") unless the copyright
  holder grants explicit written permission.
- Each copy must contain the copyright notice and the OFL text (embedded
  metadata is acceptable if user-viewable).
- `font-patcher` itself enforces awareness of this: it warns about RFN
  compliance when renaming fonts.

### Apache 2.0 set (Material Design Icons, per Pictogrammers Free License)

- Include the Apache 2.0 license text and attribution notices; state
  significant changes made to redistributed files.
- Some icons are redistributed by upstream under their respective original
  licenses; the bundled `LICENSE` is the operative notice for this tree.

### Base font

The patched fonts this suite installs (MesloLGS Nerd Font, the four
optional `.ttf` files documented in `FONT_MANIFEST.md`) combine the base
font's license with the glyph-set licenses above. `FONT_MANIFEST.md`
records the base-font provenance and defers the glyph licensing to this
file. The `.ttf` files themselves are **not** distributed in this
repository — users supply them locally (see `FONT_MANIFEST.md`, section
"Supported Local Files").

## Upstream links

- Nerd Fonts project: <https://github.com/ryanoasis/nerd-fonts/>
- Nerd Fonts releases: <https://github.com/ryanoasis/nerd-fonts/releases/latest/>
- Per-component upstream links are listed in the table above and repeated
  in each glyph set's `README.md` where one ships.
