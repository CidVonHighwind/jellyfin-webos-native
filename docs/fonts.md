# Fonts on the TV

Inventory taken directly from the configured TV on 2026-09-19. Fonts live in
`/usr/share/fonts`; `libfreetype.so.6` is installed too, although the UI renderer
uses the pure-Zig MSDF/TrueType path from `../gallery-glfw` rather than FreeType.

The native UI face is available in a useful complete family:

```
LG_Smart_UI-Light.ttf
LG_Smart_UI-Regular.ttf
LG_Smart_UI-SemiBold.ttf
LG_Smart_UI-Bold.ttf
LG_Smart_UI-{Light,Regular,SemiBold,Bold}Oblique.ttf
LG_Smart_UI_Condensed-{Light,Regular,SemiBold,Bold}.ttf
```

There are also LG Smart UI faces for Arabic/Hebrew/Thai, Amharic, Bengali,
Devanagari, Gujarati, Gurmukhi, Japanese, Kannada, Malayalam, Oriya, Simplified
and Traditional Chinese, Tamil, Telugu and Urdu. Other installed families
include Droid Sans/Serif/Mono/Kufi/Naskh and Droid Sans Fallback, Nanum Gothic,
Noto Emoji/Color Emoji, Museo Sans, Miso, Tinos, the LG Display families and
Sandstone Icons.

`uidemo` selects fonts in this order:

1. `UI_FONT=/absolute/path.ttf`, when set;
2. `/usr/share/fonts/LG_Smart_UI-Regular.ttf` on the TV;
3. Droid Sans;
4. common DejaVu/Liberation Sans paths for host development.

The selected path is printed at startup. The current atlas prewarms printable
ASCII because the remote UI demo needs no shaping or multilingual strings. The
font/parser and skyline packer already support extending this to an on-demand
Unicode cache when an application needs it.

To repeat the inventory on another set:

```sh
find /usr/share/fonts -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) | sort
```
