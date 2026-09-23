/* The handful of POSIX calls this program makes that Windows does not have.
 *
 * This exists for the local Windows UI-debugging build only - the TV and desktop Linux
 * builds include it and get nothing. Everything here is a thin spelling difference, not a
 * reimplementation: Windows has the same calls under different names.
 */
#pragma once

#ifdef _WIN32

#include <direct.h>
#include <io.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

/* Windows' mkdir carries no mode, and the mode these callers pass is advisory anyway. */
#define mkdir(path, mode) _mkdir(path)

/* _commit is fsync: flush this descriptor's buffers to the disk. */
#define fsync(fd) _commit(fd)

/* dprintf is POSIX-only. Formatting into a buffer and writing it keeps the one property
 * the callers rely on - a negative return when the write fails. */
static inline int jf_dprintf(int fd, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    va_list measure;
    va_copy(measure, args);
    const int needed = vsnprintf(NULL, 0, format, measure);
    va_end(measure);
    if (needed < 0) {
        va_end(args);
        return -1;
    }
    char stack[512];
    char *buffer = (size_t)needed < sizeof(stack) ? stack : (char *)malloc((size_t)needed + 1);
    if (buffer == NULL) {
        va_end(args);
        return -1;
    }
    vsnprintf(buffer, (size_t)needed + 1, format, args);
    va_end(args);
    const int written = _write(fd, buffer, (unsigned)needed);
    if (buffer != stack)
        free(buffer);
    return written;
}
#define dprintf jf_dprintf

/* setenv's overwrite flag has no equivalent, so it is honoured here. */
static inline int jf_setenv(const char *name, const char *value, int overwrite)
{
    if (!overwrite && getenv(name) != NULL)
        return 0;
    return _putenv_s(name, value);
}
#define setenv jf_setenv

#endif /* _WIN32 */
