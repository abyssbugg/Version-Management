# Font Manifest

This document describes MesloLGS Nerd Font files supported by the Professional Development Terminal Setup.

## Font Family

**MesloLGS Nerd Font** - A patched version of Meslo LG with Nerd Font icons.

## Supported Local Files

These files are optional and can be placed at the repository root for local installation workflows.

| File | Style | Description |
|------|-------|-------------|
| `MesloLGS NF Regular.ttf` | Regular | Standard weight for normal text |
| `MesloLGS NF Bold.ttf` | Bold | Bold weight for emphasis |
| `MesloLGS NF Italic.ttf` | Italic | Italic style for comments/strings |
| `MesloLGS NF Bold Italic.ttf` | Bold Italic | Combined bold and italic |

## Source

- **Origin**: <https://github.com/romkatv/powerlevel10k-media>
- **Upstream**: <https://github.com/ryanoasis/nerd-fonts>
- **Base Font**: Meslo LG (derivative of Apple's Menlo)

## License

The font distribution described here is **mixed-license**; this document
no longer states a single license for it. The Meslo LG base font is
licensed under Apache License 2.0 (Meslo is a derivative of Apple's
Menlo), but the patched Nerd Font bundles glyphs from icon sets with
different licenses (CC-BY-4.0, SIL OFL 1.1, MIT, Apache 2.0).

**Authoritative licensing for every component — the `font-patcher`
script and each bundled glyph set — lives in
[FontPatcher/ATTRIBUTION.md](FontPatcher/ATTRIBUTION.md)**, which was
verified against the license files shipped inside the vendored tree.
Consult it before redistributing any font produced with this setup.

## Icon Coverage

MesloLGS Nerd Font includes glyphs from the icon sets vendored under
`FontPatcher/src/glyphs/`:

- **Powerline Symbols / Powerline Extra** - Shell prompt symbols
- **Font Awesome** - General purpose icons
- **Devicons** - Programming language logos
- **Octicons** - GitHub-style icons
- **Material Design** - Google's icon set
- **VS Code Codicons** - Editor-style icons
- **Pomicons** - Pomodoro timer symbols
- **Weather Icons** - Weather symbols

Licensing differs per set — see [FontPatcher/ATTRIBUTION.md](FontPatcher/ATTRIBUTION.md).

## Installation

### Automatic

```bash
./setup-fonts-enhanced.sh
```

### Manual

1. Download or copy each `.ttf` file locally
2. Double-click each `.ttf` file
3. Click "Install" in the font preview window
4. Configure your terminal to use "MesloLGS Nerd Font"

### Programmatic

```bash
source lib/fonts.sh
font_install_bundled  # requires local MesloLGS*.ttf files at repository root
```

## Terminal Configuration

After installing fonts, configure your terminal:

| Terminal | Setting Location |
|----------|------------------|
| **VS Code** | Terminal › Integrated: Font Family → `MesloLGS Nerd Font Mono` |
| **iTerm2** | Preferences → Profiles → Text → Font |
| **Terminal.app** | Preferences → Profiles → Font |
| **Hyper** | `~/.hyper.js` → `fontFamily` |
| **Alacritty** | `~/.config/alacritty/alacritty.yml` → `font.normal.family` |
| **Windows Terminal** | Settings → Profiles → Font face |

## Verification

Test that fonts are working:

```bash
./tools/preview-nerd-fonts.sh
```

If icons display as boxes (□) or question marks (?):

1. Ensure fonts are installed
2. Restart your terminal
3. Verify terminal font setting
4. Check that "Nerd Font" variant is selected (not regular Meslo)

## Checksums

To verify font integrity:

```bash
source lib/fonts.sh
font_generate_checksums
```

## Troubleshooting

### Icons not displaying

1. **Font not installed**: Run `./setup-fonts-enhanced.sh`
2. **Wrong font selected**: Ensure "MesloLGS Nerd Font" (not "Meslo LG")
3. **Terminal cache**: Restart terminal application
4. **System cache**: Run `fc-cache -f -v` (Linux)

### Partial icon display

Some terminals have limited Unicode support. Try:

- Using iTerm2 or Alacritty on macOS
- Using a modern terminal emulator on Linux
- Enabling "Use built-in Powerline glyphs" if available

### Font looks different

MesloLGS is optimized for PowerLevel10k. If you prefer:

- **JetBrains Mono Nerd Font** - Modern, ligature-enabled
- **Fira Code Nerd Font** - Popular with ligatures
- **Hack Nerd Font** - Clean, readable

## Related Files

- `lib/fonts.sh` - Font management functions
- `tools/preview-nerd-fonts.sh` - Icon preview tool
- `setup-fonts-enhanced.sh` - Font installation script
