/* Operating-system calls this program makes that are spelled differently per platform.
 * Callers use jf_os_*; the header behind this one supplies it, so nothing above the
 * platform layer needs an #ifdef. No libc name is redefined: a macro named `mkdir` or
 * `setenv` would rewrite that name in every header included after it. */
#pragma once

#include <stddef.h>

#ifdef _WIN32
#include "os_windows.h"
#else
#include "os_posix.h"
#endif

/* Where this system keeps the faces the UI rasterises from, in the order to try them.
 * Defined in the os_*.c the build picks. */
const char *const *jf_os_font_candidates(size_t *count);
const char *const *jf_os_font_fallbacks(size_t *count);
