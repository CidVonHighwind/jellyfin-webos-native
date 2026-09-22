# Fonts on the TV

Inventory taken directly from the configured TV on 2026-09-19. Fonts live in
`/usr/share/fonts`, and the UI renderer rasterises them with the TV's own
`libfreetype.so.6`.

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

The UI selects fonts in this order:

1. `UI_FONT=/absolute/path.ttf`, when set;
2. `/usr/share/fonts/LG_Smart_UI-Regular.ttf` on the TV;
3. Droid Sans;
4. common DejaVu/Liberation Sans paths for host development.

The selected path is printed at startup. The atlas prewarms printable ASCII,
then caches additional Unicode glyphs on demand. Font data and rasterizer kernels
remain alive so new titles and symbols can extend the cache at any time. Missing
glyphs try installed Droid Sans Fallback, Droid Sans, and host DejaVu Sans faces;
unsupported characters use `?`, with misses cached to avoid repeated work.

The skyline atlas grows as needed, preserving existing glyph positions, up to
the GPU's supported texture size. The renderer prepares all text before building
UVs and uploads changed atlas pixels, replacing the texture when it grows.
Coverage depends on the installed fonts; complex-script shaping and bidirectional
layout are not implemented.

To repeat the inventory on another set:

```sh
find /usr/share/fonts -type f \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ttc' \) | sort
```
