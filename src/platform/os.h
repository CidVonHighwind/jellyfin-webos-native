/* The few operating-system calls this program makes that are spelled differently on each
 * platform.
 *
 * Callers include this header and use jf_os_*; the per-platform header behind it supplies
 * the implementation. The point is that nothing above this line needs an #ifdef, and that
 * no libc name is redefined - a macro named `mkdir` or `setenv` would rewrite those names
 * in every header included after it.
 *
 * Each implementation is a thin spelling difference, not a reimplementation. Anything that
 * needs real per-platform logic belongs in a .c file chosen by the build instead.
 */
#pragma once

#ifdef _WIN32
#include "os_windows.h"
#else
#include "os_posix.h"
#endif

/* Every platform header defines:
 *
 *   int  jf_os_mkdir(const char *path)
 *        Create one directory. Existing is not an error worth acting on, and the mode -
 *        where there is one - is 0755.
 *
 *   int  jf_os_fsync(int file)
 *        Flush this descriptor's writes to the disk. 0 on success.
 *
 *   int  jf_os_setenv(const char *name, const char *value, int overwrite)
 *        Set an environment variable, leaving an existing one alone unless overwrite.
 *
 *   int  jf_os_write_fmt(int file, const char *format, ...)
 *        Format and write to a descriptor. Negative on failure, like dprintf.
 *
 *   bool jf_os_cwd(char *out, size_t out_len)
 *        The working directory as an absolute path.
 */
