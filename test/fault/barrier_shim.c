/*
 * An LD_PRELOAD interposer that records a cell's file I/O and its durability
 * barriers, in order, so a test can ask whether an acknowledged COMMIT was
 * actually made durable before it returned.
 *
 * Why this exists. ADR-20 records that `synchronous: :normal` -- exqlite's
 * default, and so every cell's -- does not fsync at commit in WAL mode, and that
 * no test in the suite can detect it: killing a process leaves the page cache
 * intact, so every test passes under every durability level. The gap is only
 * visible in the *syscall stream*, which is what this captures.
 *
 * Why LD_PRELOAD and not device-mapper or a VM.
 *
 *   - `dm-log-writes` sees the block layer, which is strictly better, but it
 *     needs root, a privileged container and a kernel with the module. Docker
 *     Desktop's linuxkit kernel has neither `dm_log_writes` nor `dm_flakey`, so
 *     it cannot run on a developer machine at all.
 *   - Killing a QEMU guest models a guest kernel panic, not power loss: with
 *     `cache=writeback` the unflushed writes are sitting in the *host* page
 *     cache and get written out regardless.
 *   - This needs no privileges and no modules, so the same code runs in a
 *     container locally and natively on CI.
 *
 * What it therefore does NOT prove. It observes what the process asked the
 * kernel for. It cannot see the filesystem reordering metadata, and it cannot
 * see a drive that acknowledges a flush it has not performed. Those are below
 * the syscall boundary and need the block layer. A pass here means "the barrier
 * was requested before the ack", which is the invariant that was missing --
 * not "the bytes are on the platter".
 *
 * Linux only. On macOS, SIP strips DYLD_INSERT_LIBRARIES when exec'ing a
 * protected binary, and both `mix` (#!/usr/bin/env bash) and `erl` (#!/bin/sh)
 * launch through one, so the variable never reaches beam.smp.
 *
 * Environment:
 *   SHIM_LOG    file to append the trace to
 *   SHIM_MATCH  only paths containing this substring are traced
 *   SHIM_MARK   a path prefix; opening a path under it emits a MARK record,
 *               which is how the workload interleaves "this commit was
 *               acknowledged" into the syscall stream in the right order
 *   SHIM_DATA   optional; when set, every traced write's payload is appended to
 *               this blob and the trace record gains a fifth field giving its
 *               offset in it. Tier 2 (prefix replay) needs the bytes to
 *               reconstruct the database at a cut point; tier 1 does not, and
 *               leaving it unset keeps the trace small.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdarg.h>
#include <dlfcn.h>
#include <pthread.h>
#include <sys/types.h>

/* Linux-only, and defined away so this file still syntax-checks on a Mac. The
 * shim cannot *run* there, but a compile error found only inside the container
 * is a slow way to learn about a typo. */
#ifndef O_TMPFILE
#define O_TMPFILE 0
#endif

#define MAX_FD 8192
#define MAX_PATH 512

static FILE *log_fp;
static FILE *data_fp;
static long data_off;
static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
static char paths[MAX_FD][MAX_PATH];

/* The logger itself calls into libc, and fopen/fprintf open and write files. A
 * thread already inside the shim must not record its own bookkeeping, or the
 * first write to the log recurses until the stack is gone. */
static __thread int inside;

static const char *env_match, *env_mark;
static int env_read;

static void read_env_locked(void) {
  if (env_read) return;
  env_read = 1;
  env_match = getenv("SHIM_MATCH");
  env_mark = getenv("SHIM_MARK");
  FILE *(*real_fopen)(const char *, const char *) = dlsym(RTLD_NEXT, "fopen");

  const char *d = getenv("SHIM_DATA");
  if (d) data_fp = real_fopen(d, "w");

  const char *p = getenv("SHIM_LOG");
  if (!p) return;
  log_fp = real_fopen(p, "a");
  /* Line buffered, so a trace survives a workload that dies mid-run -- which is
   * the interesting case often enough to be worth the syscalls. */
  if (log_fp) setvbuf(log_fp, NULL, _IOLBF, 0);
}

/* Appends a write's payload to the blob and returns where it landed, or -1 when
 * payload capture is off. Called with the lock held, so the returned offset and
 * the trace record that names it cannot be interleaved with another thread's. */
static long stash(const void *buf, size_t n) {
  if (!data_fp) return -1;
  long at = data_off;
  if (fwrite(buf, 1, n, data_fp) != n) return -1;
  /* Flushed per write: a replay reads this file while the workload may still be
   * running, and a half-buffered blob reconstructs to garbage that looks like
   * corruption rather than like a bug in here. */
  fflush(data_fp);
  data_off += (long)n;
  return at;
}

static void emit(const char *op, const char *path, long off, long len) {
  pthread_mutex_lock(&lk);
  read_env_locked();
  if (log_fp) fprintf(log_fp, "%s\t%s\t%ld\t%ld\t-1\n", op, path, off, len);
  pthread_mutex_unlock(&lk);
}

static void note_data(const char *op, int fd, long off, long len,
                      const void *buf, size_t n) {
  if (inside || fd < 0 || fd >= MAX_FD) return;
  inside = 1;
  pthread_mutex_lock(&lk);
  read_env_locked();
  if (log_fp && paths[fd][0] != '\0') {
    long at = buf ? stash(buf, n) : -1;
    fprintf(log_fp, "%s\t%s\t%ld\t%ld\t%ld\n", op, paths[fd], off, len, at);
  }
  pthread_mutex_unlock(&lk);
  inside = 0;
}

static void note(const char *op, int fd, long off, long len) {
  note_data(op, fd, off, len, NULL, 0);
}

/* Called on every open, so it decides once per fd whether that fd is worth
 * tracing. Doing it here rather than per-write keeps the write path to a string
 * test on a fixed-size table. */
static void track(int fd, const char *path) {
  if (inside || !path) return;
  inside = 1;

  pthread_mutex_lock(&lk);
  read_env_locked();
  const char *match = env_match, *mark = env_mark;
  pthread_mutex_unlock(&lk);

  if (mark && strncmp(path, mark, strlen(mark)) == 0) {
    const char *label = strrchr(path, '/');
    emit("MARK", label ? label + 1 : path, 0, 0);
    inside = 0;
    return;
  }

  if (fd >= 0 && fd < MAX_FD) {
    pthread_mutex_lock(&lk);
    if (match && strstr(path, match)) {
      strncpy(paths[fd], path, MAX_PATH - 1);
      paths[fd][MAX_PATH - 1] = '\0';
    } else {
      paths[fd][0] = '\0';
    }
    pthread_mutex_unlock(&lk);
  }

  inside = 0;
}

#define OPEN_BODY(real_name)                                                   \
  static int (*real)(const char *, int, ...);                                  \
  if (!real) real = dlsym(RTLD_NEXT, real_name);                               \
  mode_t mode = 0;                                                             \
  if (flags & (O_CREAT | O_TMPFILE)) {                                         \
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);       \
  }                                                                            \
  int fd = real(path, flags, mode);                                            \
  track(fd, path);                                                             \
  return fd;

int open(const char *path, int flags, ...) { OPEN_BODY("open") }
int open64(const char *path, int flags, ...) { OPEN_BODY("open64") }

/* The BEAM reaches files through its own async I/O threads and does not
 * consistently use open(2); erts uses openat with AT_FDCWD. Absolute paths are
 * all this needs to resolve, and every path a cell uses is absolute. */
int openat(int dirfd, const char *path, int flags, ...) {
  static int (*real)(int, const char *, int, ...);
  if (!real) real = dlsym(RTLD_NEXT, "openat");
  mode_t mode = 0;
  if (flags & (O_CREAT | O_TMPFILE)) {
    va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap);
  }
  int fd = real(dirfd, path, flags, mode);
  track(fd, path);
  return fd;
}

ssize_t pwrite(int fd, const void *buf, size_t n, off_t off) {
  static ssize_t (*real)(int, const void *, size_t, off_t);
  if (!real) real = dlsym(RTLD_NEXT, "pwrite");
  ssize_t r = real(fd, buf, n, off);
  if (r > 0) note_data("write", fd, (long)off, (long)r, buf, (size_t)r);
  return r;
}

ssize_t pwrite64(int fd, const void *buf, size_t n, off_t off) {
  static ssize_t (*real)(int, const void *, size_t, off_t);
  if (!real) real = dlsym(RTLD_NEXT, "pwrite64");
  ssize_t r = real(fd, buf, n, off);
  if (r > 0) note_data("write", fd, (long)off, (long)r, buf, (size_t)r);
  return r;
}

ssize_t write(int fd, const void *buf, size_t n) {
  static ssize_t (*real)(int, const void *, size_t);
  if (!real) real = dlsym(RTLD_NEXT, "write");
  ssize_t r = real(fd, buf, n);
  if (r > 0) note_data("write", fd, -1, (long)r, buf, (size_t)r);
  return r;
}

/* fsync and fdatasync are both recorded as SYNC. SQLite's unix VFS picks
 * between them by build flags and by the fullfsync pragma, and the invariant
 * under test does not care which was chosen -- only that a barrier on the WAL
 * was requested and returned before the commit was acknowledged. */
int fsync(int fd) {
  static int (*real)(int);
  if (!real) real = dlsym(RTLD_NEXT, "fsync");
  int r = real(fd);
  note("SYNC", fd, 0, 0);
  return r;
}

int fdatasync(int fd) {
  static int (*real)(int);
  if (!real) real = dlsym(RTLD_NEXT, "fdatasync");
  int r = real(fd);
  note("SYNC", fd, 0, 0);
  return r;
}

int ftruncate(int fd, off_t len) {
  static int (*real)(int, off_t);
  if (!real) real = dlsym(RTLD_NEXT, "ftruncate");
  int r = real(fd, len);
  note("truncate", fd, (long)len, 0);
  return r;
}
