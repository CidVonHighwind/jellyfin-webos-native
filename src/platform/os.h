/* Operating-system calls this program makes that are spelled differently per platform.
 * Callers use jf_os_*; the header behind this one supplies it, so nothing above the
 * platform layer needs an #ifdef. No libc name is redefined: a macro named `mkdir` or
 * `setenv` would rewrite that name in every header included after it. */
#pragma once

#ifdef _WIN32
#include "os_windows.h"
#else
#include "os_posix.h"
#endif
