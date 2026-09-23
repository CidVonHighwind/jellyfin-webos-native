/* The Windows side of os.h. Include os.h, not this. */
#pragma once

/* winsock2.h before anything that might reach windows.h, or the older winsock wins. */
#include <winsock2.h>
#include <ws2tcpip.h>

#include <direct.h>
#include <io.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

/* Where the UI's faces are looked for, in order. Segoe UI is the system face every
 * supported Windows carries; the other two are there in case it has been removed. */
#define JF_OS_FONT_CANDIDATES                                                                \
    "C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf", "C:/Windows/Fonts/tahoma.ttf"

/* Faces consulted for codepoints the primary one has no glyph for. */
#define JF_OS_FONT_FALLBACKS "C:/Windows/Fonts/seguisym.ttf", "C:/Windows/Fonts/arial.ttf"

/* No mode here; Windows has no permission bits to carry. */
static inline int jf_os_mkdir(const char *path) { return _mkdir(path); }

/* _commit is fsync under another name. */
static inline int jf_os_fsync(int file) { return _commit(file); }

static inline int jf_os_setenv(const char *name, const char *value, int overwrite)
{
    /* _putenv_s always overwrites, so the flag is honoured here. */
    if (!overwrite && getenv(name) != NULL)
        return 0;
    return _putenv_s(name, value);
}

/* There is no dprintf. Formatting into a buffer and writing it keeps the property the
 * callers rely on: negative when the write does not complete. */
static inline int jf_os_write_fmt(int file, const char *format, ...)
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
    const int written = _write(file, buffer, (unsigned)needed);
    if (buffer != stack)
        free(buffer);
    return written;
}

static inline bool jf_os_cwd(char *out, size_t out_len)
{
    return _getcwd(out, (int)out_len) != NULL;
}

/* ------------------------------------------------------------------ sockets */

/* Unsigned, so the usual `fd < 0` test would never fire. */
typedef SOCKET jf_os_socket;

/* Winsock has to be started before any socket call - and gethostname is one. Repeated
 * calls are counted by Winsock itself, so this is safe to call more than once. */
static inline bool jf_os_net_init(void)
{
    WSADATA wsa;
    return WSAStartup(MAKEWORD(2, 2), &wsa) == 0;
}

static inline bool jf_os_socket_valid(jf_os_socket socket_fd)
{
    return socket_fd != INVALID_SOCKET;
}

static inline void jf_os_socket_close(jf_os_socket socket_fd) { closesocket(socket_fd); }

/* A count of milliseconds here, where POSIX takes a struct timeval. */
static inline int jf_os_socket_recv_timeout(jf_os_socket socket_fd, int milliseconds)
{
    const DWORD timeout = (DWORD)milliseconds;
    return setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&timeout,
                      sizeof(timeout));
}

static inline int jf_os_socket_broadcast(jf_os_socket socket_fd)
{
    const int yes = 1;
    return setsockopt(socket_fd, SOL_SOCKET, SO_BROADCAST, (const char *)&yes, sizeof(yes));
}
