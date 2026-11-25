#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <poll.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

ssize_t write(int fd, const void *bytes, size_t length)
{
    ssize_t (*real_write)(int, const void *, size_t) = dlsym(RTLD_NEXT, "write");
    struct stat status;

    if (fd <= STDERR_FILENO || length <= 4096 || fstat(fd, &status) != 0 ||
        !S_ISFIFO(status.st_mode))
        return real_write(fd, bytes, length);

    // Send one byte so the helper closes stdin only after ae enters write.
    // POLLERR on a pipe writer means all readers closed their descriptors.
    ssize_t first = real_write(fd, bytes, 1);
    if (first != 1)
        return first;

    struct pollfd pipe = { .fd = fd };
    int ready;
    do {
        ready = poll(&pipe, 1, 5000);
    } while (ready < 0 && errno == EINTR);

    ssize_t result = real_write(fd, (const char *)bytes + 1, length - 1);
    int saved_errno = errno;
    if (ready == 1 && (pipe.revents & POLLERR) && result == -1 && saved_errno == EPIPE)
        dprintf(STDERR_FILENO, "image-jail: queued write returned EPIPE\n");
    errno = saved_errno;
    return result < 0 ? result : result + 1;
}
