#include "os.h"

/* The TV's own face first, then what a desktop distribution is likely to carry. */
static const char *const candidates[] = {
    "/usr/share/fonts/LG_Smart_UI-Regular.ttf",
    "/usr/share/fonts/DroidSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
};

static const char *const fallbacks[] = {
    "/usr/share/fonts/DroidSansFallback.ttf",
    "/usr/share/fonts/DroidSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
};

const char *const *jf_os_font_candidates(size_t *count)
{
    *count = sizeof(candidates) / sizeof(*candidates);
    return candidates;
}

const char *const *jf_os_font_fallbacks(size_t *count)
{
    *count = sizeof(fallbacks) / sizeof(*fallbacks);
    return fallbacks;
}
