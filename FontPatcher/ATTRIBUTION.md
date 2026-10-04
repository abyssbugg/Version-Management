# FontPatcher Attribution and Licensing

This document consolidates the licensing information for the vendored
`FontPatcher/` tree (Nerd Fonts `font-patcher` script plus its glyph-set
sources). It supersedes any blanket license claim made elsewhere in this
repository, including `FONT_MANIFEST.md`.

Provenance of the vendored tree is documented in `FontPatcher/readme.md`:
an archive extracted from the Nerd Fonts project at version **3.4.0**
(commit `dc4e3309d6c1483532ccaefafd1e940d7c80dec1`, 2025-04-24).

Every entry below was verified against the license files that ship inside
this vendored tree (`FontPatcher/src/glyphs/*/LICENSE*`, `OFL*`). Where a
component's license is **not** stated in the bundled files, that is called
out explicitly rather than guessed.

## Component license table

| Component | Path | License (verified from bundled file) | License file | Version (per README) | Upstream |
|-----------|------|--------------------------------------|--------------|----------------------|----------|
| font-patcher script + name parser | `FontPatcher/font-patcher`, `FontPatcher/bin/scripts/name_parser/` | Not stated in the bundled files (no LICENSE ships in this archive; see note below) | — | Nerd Fonts 3.4.0, script_version 4.20.3 | <https://github.com/ryanoasis/nerd-fonts/> |
| glyph-set database | `FontPatcher/glyphnames.json` | Part of the font-patcher distribution (no separate license file) | — | Nerd Fonts 3.4.0 | <https://github.com/ryanoasis/nerd-fonts/> |
| codicons | `FontPatcher/src/glyphs/codicons/` | CC-BY-4.0 (Creative Commons Attribution 4.0 International) | `LICENSE.txt` | 0.0.35 | <https://github.com/microsoft/vscode-codicons> |
| devicons | `FontPatcher/src/glyphs/devicons/` | Not stated in the bundled files (see note below) | — | 2.16.0.custom | <https://github.com/devicons/devicon> |
| Font Awesome | `FontPatcher/src/glyphs/font-awesome/` | CC-BY-4.0 (icons), SIL OFL 1.1 (fonts; Reserved Font Name "Font Awesome"), MIT (code) | `LICENSE.txt` | 6.5.1.custom | <https://github.com/FortAwesome/Font-Awesome> |
| Material Design Icons | `FontPatcher/src/glyphs/materialdesign/` | Pictogrammers Free License: Apache 2.0 (icons and fonts), MIT (code) | `LICENSE` | Last fetched 2022-10-06 | <https://github.com/Templarian/MaterialDesign-Font> |
| Octicons | `FontPatcher/src/glyphs/octicons/` | MIT (Copyright (c) 2023 GitHub Inc.) | `LICENSE` | — (no README in bundled dir) | Not stated in bundled files; copyright holder is GitHub Inc. |
| Pomicons | `FontPatcher/src/glyphs/pomicons/` | SIL OFL 1.1 (Reserved Font Name "Pomicons") | `LICENSE` | 1.001 | <https://github.com/gabrielelana/pomicons> |
| Powerline Extra Symbols | `FontPatcher/src/glyphs/powerline-extra/` | MIT (Copyright (c) 2016 Ryan L McIntyre) | `LICENSE` | 1.200 (Nerd Fonts-modified) | <https://github.com/ryanoasis/powerline-extra-symbols> |
| Powerline Symbols | `FontPatcher/src/glyphs/powerline-symbols/` | MIT-style notice (Copyright 2013 Kim Silkebækken and other contributors) | `LICENSE.txt` | 1.000 (from about 2013) | <https://github.com/powerline/powerline> (stated in license text) |
| Weather Icons | `FontPatcher/src/glyphs/weather-icons/` | SIL OFL 1.1 (OFL.txt is the license template with placeholder copyright fields) | `OFL.txt`, `OFL-FAQ.txt` | — (no README in bundled dir) | Not stated in bundled files |
| extra glyph source | `FontPatcher/src/glyphs/extraglyphs.sfd` | FontForge source file within the font-patcher distribution (no separate license file) | — | — | — |

Notes on the two components whose licenses could not be verified from the
bundled files:

- **font-patcher script**: the bundled `readme.md` identifies the upstream
  project but carries no license statement. Verify the current license
  against the upstream repository before redistributing this script
  outside a Nerd Fonts release.
- **devicons**: the bundled `README.md` identifies the upstream project and
  version but carries no license statement. Verify the license
  (`<https://github.com/devicons/devicon>`) before redistributing beyond
  the Nerd Fonts distribution.

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
