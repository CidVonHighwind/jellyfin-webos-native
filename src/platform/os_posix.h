/* The POSIX side of os.h. Include os.h, not this. */
#pragma once

#include <arpa/inet.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

/* The TV's own face first, then what a desktop distribution is likely to carry. */
#define JF_OS_FONT_CANDIDATES                                                                \
    "/usr/share/fonts/LG_Smart_UI-Regular.ttf", "/usr/share/fonts/DroidSans.ttf",            \
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",                                   \
        "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",                  \
        "/usr/share/fonts/TTF/DejaVuSans.ttf"

#define JF_OS_FONT_FALLBACKS                                                                 \
    "/usr/share/fonts/DroidSansFallback.ttf", "/usr/share/fonts/DroidSans.ttf",              \
        "/usr/share/fonts/TTF/DejaVuSans.ttf",                                               \
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"

static inline int jf_os_mkdir(const char *path) { return mkdir(path, 0755); }

static inline int jf_os_fsync(int file) { return fsync(file); }

static inline int jf_os_setenv(const char *name, const char *value, int overwrite)
{
    return setenv(name, value, overwrite);
}

static inline int jf_os_write_fmt(int file, const char *format, ...)
{
    va_list args;
    va_start(args, format);
    const int written = vdprintf(file, format, args);
    va_end(args);
    return written;
}

typedef int jf_os_socket;

static inline bool jf_os_net_init(void) { return true; }

static inline bool jf_os_socket_valid(jf_os_socket socket_fd) { return socket_fd >= 0; }

static inline void jf_os_socket_close(jf_os_socket socket_fd) { close(socket_fd); }

static inline int jf_os_socket_recv_timeout(jf_os_socket socket_fd, int milliseconds)
{
    const struct timeval timeout = {milliseconds / 1000, (milliseconds % 1000) * 1000};
    return setsockopt(socket_fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
}

static inline int jf_os_socket_broadcast(jf_os_socket socket_fd)
{
    const int yes = 1;
    return setsockopt(socket_fd, SOL_SOCKET, SO_BROADCAST, &yes, sizeof(yes));
}

/* /proc/self/cwd rather than getcwd: an installed app is started through symlinks, and it
 * is the resolved path that carries the app id its caller reads. */
static inline bool jf_os_cwd(char *out, size_t out_len)
{
    const ssize_t n = readlink("/proc/self/cwd", out, out_len - 1);
    if (n <= 0)
        return false;
    out[n] = '\0';
    return true;
}
