#include "RuntimeShim.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

typedef int (*rr_disclaim_fn)(posix_spawnattr_t *, int);
typedef int (*rr_sandbox_fn)(pid_t, const char *, int, ...);

int rr_sandbox_state(void) {
    rr_sandbox_fn check = (rr_sandbox_fn)dlsym(RTLD_DEFAULT, "sandbox_check");
    if (!check) return -1;
    int value = check(getpid(), NULL, 0);
    return value < 0 ? -1 : (value > 0 ? 1 : 0);
}

char *rr_executable_path(void) {
    uint32_t size = 0;
    _NSGetExecutablePath(NULL, &size);
    char *buffer = malloc(size);
    if (!buffer) return NULL;
    char *resolved = NULL;
    if (_NSGetExecutablePath(buffer, &size) == 0) resolved = realpath(buffer, NULL);
    free(buffer);
    return resolved;
}

void rr_free(void *pointer) { free(pointer); }
void rr_close(int fd) { if (fd >= 0) close(fd); }

static int make_pipe(int fds[2]) {
    if (pipe(fds) != 0) return errno;
    // Keep internal descriptors away from stdio even if the caller closed stdio.
    for (int i = 0; i < 2; i++) {
        int moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 3);
        if (moved < 0) {
            int error = errno;
            close(fds[0]); close(fds[1]);
            fds[0] = fds[1] = -1;
            return error;
        }
        close(fds[i]);
        fds[i] = moved;
    }
    return 0;
}

int rr_spawn(const char *path, char *const argv[], char *const environment[],
             rr_child *child, int *disclaim_refused) {
    *disclaim_refused = 0;
    rr_disclaim_fn disclaim = (rr_disclaim_fn)dlsym(RTLD_DEFAULT, "responsibility_spawnattrs_setdisclaim");
    if (!disclaim) { *disclaim_refused = 1; return ENOTSUP; }
    posix_spawnattr_t attributes;
    int error = posix_spawnattr_init(&attributes);
    if (error) return error;
    error = disclaim(&attributes, 1);
    if (error) {
        *disclaim_refused = 1;
        posix_spawnattr_destroy(&attributes);
        return error;
    }
    int pipes[3][2] = {{-1, -1}, {-1, -1}, {-1, -1}};
    posix_spawn_file_actions_t actions;
    int actions_ready = 0;
    short flags = POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP |
                  POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK;
    error = posix_spawnattr_setflags(&attributes, flags);
    if (!error) error = posix_spawnattr_setpgroup(&attributes, 0);
    // CLI signal forwarding may ignore SIGTERM/SIGINT. Don't inherit that into workers.
    sigset_t defaults, mask;
    sigemptyset(&defaults); sigemptyset(&mask);
    int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGCHLD};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) sigaddset(&defaults, signals[i]);
    if (!error) error = posix_spawnattr_setsigdefault(&attributes, &defaults);
    if (!error) error = posix_spawnattr_setsigmask(&attributes, &mask);
    for (int i = 0; i < 3 && !error; i++) error = make_pipe(pipes[i]);
    if (!error) {
        error = posix_spawn_file_actions_init(&actions);
        actions_ready = !error;
    }
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[0][0], STDIN_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[1][1], STDOUT_FILENO);
    if (!error) error = posix_spawn_file_actions_adddup2(&actions, pipes[2][1], STDERR_FILENO);
    // Only parent ends are nonblocking; the worker sees normal blocking stdio.
    int parent_ends[] = {pipes[0][1], pipes[1][0], pipes[2][0]};
    for (int i = 0; i < 3 && !error; i++) {
        if (fcntl(parent_ends[i], F_SETFL, O_NONBLOCK) < 0) error = errno;
    }
    if (!error && fcntl(parent_ends[0], F_SETNOSIGPIPE, 1) < 0) error = errno;
    pid_t pid = 0;
    if (!error) error = posix_spawn(&pid, path, &actions, &attributes, argv, environment);
    if (actions_ready) posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (error) {
        for (int i = 0; i < 3; i++) {
            rr_close(pipes[i][0]); rr_close(pipes[i][1]);
        }
        return error;
    }
    rr_close(pipes[0][0]); rr_close(pipes[1][1]); rr_close(pipes[2][1]);
    *child = (rr_child){pid, parent_ends[0], parent_ends[1], parent_ends[2]};
    return 0;
}

int rr_poll(int input, int output, int diagnostic, int milliseconds, int *ready) {
    struct pollfd fds[] = {{input, POLLOUT, 0}, {output, POLLIN, 0}, {diagnostic, POLLIN, 0}};
    int count = poll(fds, 3, milliseconds);
    if (count < 0) return errno == EINTR ? 0 : errno;
    *ready = 0;
    for (int i = 0; i < 3; i++) if (fds[i].revents) *ready |= 1 << i;
    return 0;
}

long rr_read(int fd, void *bytes, size_t length, int *code) {
    ssize_t value = read(fd, bytes, length);
    if (value >= 0) return value;
    *code = errno;
    return errno == EAGAIN || errno == EINTR ? -1 : -2;
}

long rr_write(int fd, const void *bytes, size_t length, int *code) {
    ssize_t value = write(fd, bytes, length);
    if (value >= 0) return value;
    *code = errno;
    return errno == EAGAIN || errno == EINTR ? -1 : -2;
}

int rr_write_all(int fd, const void *bytes, size_t length) {
    if (fcntl(fd, F_SETNOSIGPIPE, 1) < 0) return errno;
    size_t offset = 0;
    while (offset < length) {
        int error = 0;
        long count = rr_write(fd, (const char *)bytes + offset, length - offset, &error);
        if (count == -1 && error == EINTR) continue;
        if (count <= 0) return error ? error : EIO;
        offset += (size_t)count;
    }
    return 0;
}

int rr_reap(int32_t pid, int *status) {
    siginfo_t info = {0};
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) < 0)
        return errno == EINTR ? 0 : -1;
    if (!info.si_pid) return 0;
    *status = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
    return 1;
}

int rr_stop(int32_t pid, int *status) {
    // Observe without reaping so the process group ID cannot be reused before
    // it is signalled. A finished leader needs no grace period of its own.
    int observed_status = 0;
    int exited = rr_reap(pid, &observed_status);
    kill(-pid, SIGTERM);
    kill(pid, SIGTERM);
    if (exited != 1) {
        struct timespec grace = {0, 100000000};
        while (nanosleep(&grace, &grace) < 0 && errno == EINTR) {}
    }
    // Always terminate remaining group members, even if the leader had exited.
    kill(-pid, SIGKILL);
    kill(pid, SIGKILL);
    int raw = 0;
    pid_t result;
    do { result = waitpid(pid, &raw, 0); } while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    *status = WIFEXITED(raw) ? WEXITSTATUS(raw) : 128 + WTERMSIG(raw);
    return 0;
}
