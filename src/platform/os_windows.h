/* The Windows side of os.h. Include os.h, not this. */
#pragma once

/* winsock2.h first, or an indirect windows.h pulls in the older winsock instead. */
#include <winsock2.h>
#include <ws2tcpip.h>

#include <direct.h>
#include <io.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

static inline int jf_os_mkdir(const char *path) { return _mkdir(path); }

static inline int jf_os_fsync(int file) { return _commit(file); }

/* No dprintf. Formatting into a buffer keeps what the callers rely on: negative when the
 * write does not complete. */
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

/* Unsigned, so the usual `fd < 0` test would never fire. */
typedef SOCKET jf_os_socket;

/* Winsock counts its own callers, so starting it more than once is safe. */
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

/* Milliseconds here, where POSIX takes a struct timeval. */
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
