#include "os.h"

/* Segoe UI is the system face every supported Windows carries; the rest are for when it
 * has been removed. */
static const char *const candidates[] = {
    "C:/Windows/Fonts/segoeui.ttf",
    "C:/Windows/Fonts/arial.ttf",
    "C:/Windows/Fonts/tahoma.ttf",
};

static const char *const fallbacks[] = {
    "C:/Windows/Fonts/seguisym.ttf",
    "C:/Windows/Fonts/arial.ttf",
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
