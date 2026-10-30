#pragma once
#include <stddef.h>
#include <stdint.h>

// All return codes are errno values unless the function documents otherwise.
// A refused disclaim operation never spawns a child.
typedef struct {
    int32_t pid;
    int input_fd;
    int output_fd;
    int error_fd;
} rr_child;

// 0=not sandboxed, 1=sandboxed, -1=SPI absent or inconclusive; not a TCC check.
int rr_sandbox_state(void);
// Allocated canonical executable path; release with rr_free.
char *rr_executable_path(void);
void rr_free(void *pointer);
int rr_spawn(const char *path, char *const argv[], char *const environment[],
             rr_child *child, int *disclaim_refused);
void rr_close(int fd);
// Poll ready flags: bit 1=input writable, 2=output readable/closed, 4=stderr readable/closed.
int rr_poll(int input, int output, int diagnostic, int milliseconds, int *ready);
// Nonblocking transfer: >0 bytes, 0 EOF, -1 would-block/interrupted, -2 error (errno in code).
long rr_read(int fd, void *bytes, size_t length, int *code);
long rr_write(int fd, const void *bytes, size_t length, int *code);
// Blocking worker transfer, with SIGPIPE suppressed per descriptor.
int rr_write_all(int fd, const void *bytes, size_t length);
// Observe without reaping: 1=exited, 0=running, -1=error. Exit code, or 128+signal.
// rr_stop must subsequently reap, even after an observed natural exit.
int rr_reap(int32_t pid, int *status);
// TERM process group, 100ms grace, KILL and wait. Also stops leftover descendants.
int rr_stop(int32_t pid, int *status);
