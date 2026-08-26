/*
 * WASI preview1 shim over POSIX for pglite.wasi (wasm2c build).
 * See wasi_shim.h. Semantics follow the preview1 spec as exercised by
 * wasi-libc; verified against the same module running under uvwasi.
 */
#include "wasi_shim.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

#include "pglite.h" /* import prototypes we implement */

/* ---------------- WASI ABI constants ---------------- */

#define WASI_ESUCCESS 0
#define WASI_EBADF 8
#define WASI_EFAULT 21
#define WASI_EINVAL 28
#define WASI_EIO 29
#define WASI_ENOENT 44
#define WASI_ENOSYS 52
#define WASI_ENOTDIR 54
#define WASI_ENOTSUP 58
#define WASI_ENOTCAPABLE 76

/* filetype */
#define WASI_FT_UNKNOWN 0
#define WASI_FT_BLOCK 1
#define WASI_FT_CHAR 2
#define WASI_FT_DIR 3
#define WASI_FT_REG 4
#define WASI_FT_SYMLINK 7

/* oflags */
#define WASI_O_CREAT 1
#define WASI_O_DIRECTORY 2
#define WASI_O_EXCL 4
#define WASI_O_TRUNC 8

/* fdflags */
#define WASI_FDFLAG_APPEND 1
#define WASI_FDFLAG_DSYNC 2
#define WASI_FDFLAG_NONBLOCK 4
#define WASI_FDFLAG_RSYNC 8
#define WASI_FDFLAG_SYNC 16

/* rights bits we care about */
#define WASI_RIGHT_FD_READ (1ULL << 1)
#define WASI_RIGHT_FD_WRITE (1ULL << 6)

/* lookupflags */
#define WASI_LOOKUP_SYMLINK_FOLLOW 1

/* clockid */
#define WASI_CLOCK_REALTIME 0
#define WASI_CLOCK_MONOTONIC 1

/* poll subscription tags */
#define WASI_EVENTTYPE_CLOCK 0
#define WASI_EVENTTYPE_FD_READ 1
#define WASI_EVENTTYPE_FD_WRITE 2
#define WASI_SUBCLOCKFLAGS_ABSTIME 1

/* whence: preview1 = SET 0, CUR 1, END 2 */

typedef struct w2c_wasi__snapshot__preview1 W;

/* ---------------- errno mapping ---------------- */

static uint32_t wasi_errno(int e) {
  switch (e) {
    case 0: return 0;
    case E2BIG: return 1;
    case EACCES: return 2;
    case EAGAIN: return 6;
    case EBADF: return 8;
    case EBUSY: return 10;
    case EDEADLK: return 16;
    case EDQUOT: return 19;
    case EEXIST: return 20;
    case EFAULT: return 21;
    case EFBIG: return 22;
    case EINTR: return 27;
    case EINVAL: return 28;
    case EIO: return 29;
    case EISDIR: return 31;
    case ELOOP: return 32;
    case EMFILE: return 33;
    case EMLINK: return 34;
    case ENAMETOOLONG: return 37;
    case ENFILE: return 41;
    case ENODEV: return 43;
    case ENOENT: return 44;
    case ENOLCK: return 46;
    case ENOMEM: return 48;
    case ENOSPC: return 51;
    case ENOSYS: return 52;
    case ENOTDIR: return 54;
    case ENOTEMPTY: return 55;
    case ENOTSUP: return 58;
    case ENOTTY: return 59;
    case ENXIO: return 60;
    case EOVERFLOW: return 61;
    case EPERM: return 63;
    case EPIPE: return 64;
    case ERANGE: return 68;
    case EROFS: return 69;
    case ESPIPE: return 70;
    case ESRCH: return 71;
    case ESTALE: return 72;
    case ETIMEDOUT: return 73;
    case ETXTBSY: return 74;
    case EXDEV: return 75;
    default: return WASI_EIO;
  }
}

/* ---------------- guest memory helpers ---------------- */

static void* gptr(W* w, u32 off, u32 len) {
  wasm_rt_memory_t* m = w->mem;
  if (!m || (uint64_t)off + len > m->size)
    return NULL;
  return m->data + off;
}

static int gread_u32(W* w, u32 off, u32* out) {
  void* p = gptr(w, off, 4);
  if (!p) return -1;
  memcpy(out, p, 4);
  return 0;
}

static int gwrite_u32(W* w, u32 off, u32 v) {
  void* p = gptr(w, off, 4);
  if (!p) return -1;
  memcpy(p, &v, 4);
  return 0;
}

static int gwrite_u64(W* w, u32 off, u64 v) {
  void* p = gptr(w, off, 8);
  if (!p) return -1;
  memcpy(p, &v, 8);
  return 0;
}

/* Copy a guest path (not NUL-terminated) into buf. */
static int gpath(W* w, u32 off, u32 len, char* buf, size_t cap) {
  if (len >= cap) return -1;
  void* p = gptr(w, off, len);
  if (!p) return -1;
  memcpy(buf, p, len);
  buf[len] = 0;
  return 0;
}

/* ---------------- fd table ---------------- */

static wasi_fd_entry* fd_get(W* w, u32 fd) {
  if (fd >= WASI_SHIM_MAX_FDS) return NULL;
  wasi_fd_entry* e = &w->fds[fd];
  if (e->host_fd < 0) return NULL;
  return e;
}

/* wasi-libc's `open` relies on lowest-free allocation (the module's initdb
 * boot replay does close(0); open(...) and expects fd 0). */
static int fd_alloc(W* w) {
  for (int i = 0; i < WASI_SHIM_MAX_FDS; i++)
    if (w->fds[i].host_fd < 0) return i;
  return -1;
}

static uint8_t mode_to_filetype(mode_t m) {
  if (S_ISDIR(m)) return WASI_FT_DIR;
  if (S_ISREG(m)) return WASI_FT_REG;
  if (S_ISLNK(m)) return WASI_FT_SYMLINK;
  if (S_ISCHR(m)) return WASI_FT_CHAR;
  if (S_ISBLK(m)) return WASI_FT_BLOCK;
  return WASI_FT_UNKNOWN;
}

static void fd_set_entry(W* w, int fd, int host_fd, uint8_t ft, uint16_t fl,
                         int preopen) {
  w->fds[fd].host_fd = host_fd;
  w->fds[fd].filetype = ft;
  w->fds[fd].fdflags = fl;
  w->fds[fd].preopen = preopen;
}

/* ---------------- init / dispose ---------------- */

int wasi_shim_init(W* w, const char* root, const char** argv, int argc,
                   const char** envp, int envc) {
  memset(w, 0, sizeof(*w));
  w->argv = argv;
  w->argc = argc;
  w->envp = envp;
  w->envc = envc;
  w->log_fd = -1;
  for (int i = 0; i < WASI_SHIM_MAX_FDS; i++) w->fds[i].host_fd = -1;

  char path[1024];

  /* <root>/dev/urandom must exist (the guest opens it by path). */
  snprintf(path, sizeof path, "%s/dev", root);
  mkdir(path, 0755);
  snprintf(path, sizeof path, "%s/dev/urandom", root);
  int ur = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (ur < 0) return -1;
  uint8_t seed[128];
  arc4random_buf(seed, sizeof seed);
  (void)!write(ur, seed, sizeof seed);
  close(ur);

  /* guest stdio -> <root>/pg.log */
  snprintf(path, sizeof path, "%s/pg.log", root);
  w->log_fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
  if (w->log_fd < 0) return -1;
  fd_set_entry(w, 0, open("/dev/null", O_RDONLY), WASI_FT_CHAR, 0, -1);
  fd_set_entry(w, 1, w->log_fd, WASI_FT_CHAR, WASI_FDFLAG_APPEND, -1);
  fd_set_entry(w, 2, w->log_fd, WASI_FT_CHAR, WASI_FDFLAG_APPEND, -1);

  /* preopens: fd 3 = /tmp, fd 4 = /dev */
  static const char* guests[2] = {"/tmp", "/dev"};
  static const char* subdirs[2] = {"tmp", "dev"};
  for (int i = 0; i < 2; i++) {
    wasi_preopen* p = &w->preopens[w->n_preopens];
    snprintf(p->host_path, sizeof p->host_path, "%s/%s", root, subdirs[i]);
    p->guest_path = guests[i];
    p->host_fd = open(p->host_path, O_RDONLY | O_DIRECTORY);
    if (p->host_fd < 0) return -1;
    fd_set_entry(w, 3 + i, p->host_fd, WASI_FT_DIR, 0, w->n_preopens);
    w->n_preopens++;
  }
  return 0;
}

void wasi_shim_dispose(W* w) {
  /* close everything we own exactly once (log_fd is shared by 1 and 2,
   * preopen fds are shared with their table slots) */
  for (int i = 0; i < WASI_SHIM_MAX_FDS; i++) {
    int hfd = w->fds[i].host_fd;
    if (hfd < 0) continue;
    w->fds[i].host_fd = -1;
    if (hfd == w->log_fd) continue;
    bool is_preopen_fd = false;
    for (int j = 0; j < w->n_preopens; j++)
      if (w->preopens[j].host_fd == hfd) is_preopen_fd = true;
    if (is_preopen_fd) continue;
    close(hfd);
  }
  for (int j = 0; j < w->n_preopens; j++) close(w->preopens[j].host_fd);
  if (w->log_fd >= 0) close(w->log_fd);
  w->log_fd = -1;
  w->n_preopens = 0;
}

/* ---------------- trace helper ---------------- */

#define TRACE(w, ...)                        \
  do {                                       \
    if ((w)->trace) {                        \
      fprintf(stderr, "wasi: " __VA_ARGS__); \
      fputc('\n', stderr);                   \
    }                                        \
  } while (0)

/* ---------------- args / environ ---------------- */

u32 w2c_wasi__snapshot__preview1_args_sizes_get(W* w, u32 count_p, u32 size_p) {
  u32 total = 0;
  for (int i = 0; i < w->argc; i++) total += (u32)strlen(w->argv[i]) + 1;
  if (gwrite_u32(w, count_p, (u32)w->argc) || gwrite_u32(w, size_p, total))
    return WASI_EFAULT;
  return 0;
}

u32 w2c_wasi__snapshot__preview1_args_get(W* w, u32 argv_p, u32 buf_p) {
  u32 off = buf_p;
  for (int i = 0; i < w->argc; i++) {
    size_t n = strlen(w->argv[i]) + 1;
    void* dst = gptr(w, off, (u32)n);
    if (!dst || gwrite_u32(w, argv_p + 4 * (u32)i, off)) return WASI_EFAULT;
    memcpy(dst, w->argv[i], n);
    off += (u32)n;
  }
  return 0;
}

u32 w2c_wasi__snapshot__preview1_environ_sizes_get(W* w, u32 count_p,
                                                   u32 size_p) {
  u32 total = 0;
  for (int i = 0; i < w->envc; i++) total += (u32)strlen(w->envp[i]) + 1;
  if (gwrite_u32(w, count_p, (u32)w->envc) || gwrite_u32(w, size_p, total))
    return WASI_EFAULT;
  return 0;
}

u32 w2c_wasi__snapshot__preview1_environ_get(W* w, u32 env_p, u32 buf_p) {
  u32 off = buf_p;
  for (int i = 0; i < w->envc; i++) {
    size_t n = strlen(w->envp[i]) + 1;
    void* dst = gptr(w, off, (u32)n);
    if (!dst || gwrite_u32(w, env_p + 4 * (u32)i, off)) return WASI_EFAULT;
    memcpy(dst, w->envp[i], n);
    off += (u32)n;
  }
  return 0;
}

/* ---------------- clocks / random / yield / exit ---------------- */

u32 w2c_wasi__snapshot__preview1_clock_time_get(W* w, u32 id, u64 precision,
                                                u32 time_p) {
  (void)precision;
  struct timespec ts;
  clockid_t cid;
  switch (id) {
    case WASI_CLOCK_REALTIME: cid = CLOCK_REALTIME; break;
    case WASI_CLOCK_MONOTONIC: cid = CLOCK_MONOTONIC; break;
    case 2: cid = CLOCK_PROCESS_CPUTIME_ID; break;
    case 3: cid = CLOCK_THREAD_CPUTIME_ID; break;
    default: return WASI_EINVAL;
  }
  if (clock_gettime(cid, &ts)) return wasi_errno(errno);
  u64 ns = (u64)ts.tv_sec * 1000000000ull + (u64)ts.tv_nsec;
  return gwrite_u64(w, time_p, ns) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_random_get(W* w, u32 buf_p, u32 len) {
  void* p = gptr(w, buf_p, len);
  if (!p) return WASI_EFAULT;
  arc4random_buf(p, len);
  return 0;
}

u32 w2c_wasi__snapshot__preview1_sched_yield(W* w) {
  (void)w;
  sched_yield();
  return 0;
}

void w2c_wasi__snapshot__preview1_proc_exit(W* w, u32 code) {
  w->exit_code = code;
  w->exited = true;
  TRACE(w, "proc_exit(%u)", code);
  if (w->exit_jmp_armed) longjmp(w->exit_jmp, 1);
  /* No handler armed: treat as fatal. */
  fprintf(stderr, "wasi: unhandled proc_exit(%u)\n", code);
  abort();
}

/* ---------------- fd ops ---------------- */

u32 w2c_wasi__snapshot__preview1_fd_close(W* w, u32 fd) {
  wasi_fd_entry* e = fd_get(w, fd);
  TRACE(w, "fd_close(%u)", fd);
  if (!e) return WASI_EBADF;
  /* never close the shared log fd / preopen host fds out from under us */
  int hfd = e->host_fd;
  e->host_fd = -1;
  if (hfd != w->log_fd && e->preopen < 0) close(hfd);
  e->preopen = -1;
  return 0;
}

u32 w2c_wasi__snapshot__preview1_fd_renumber(W* w, u32 from, u32 to) {
  wasi_fd_entry* ef = fd_get(w, from);
  TRACE(w, "fd_renumber(%u -> %u)", from, to);
  if (!ef || to >= WASI_SHIM_MAX_FDS) return WASI_EBADF;
  wasi_fd_entry* et = &w->fds[to];
  if (et->host_fd >= 0 && et->host_fd != w->log_fd && et->preopen < 0)
    close(et->host_fd);
  *et = *ef;
  ef->host_fd = -1;
  ef->preopen = -1;
  return 0;
}

static int iovs_to_host(W* w, u32 iovs_p, u32 n, struct iovec* iov,
                        u32 max_iov) {
  if (n > max_iov) return -1;
  for (u32 i = 0; i < n; i++) {
    u32 buf, len;
    if (gread_u32(w, iovs_p + 8 * i, &buf) ||
        gread_u32(w, iovs_p + 8 * i + 4, &len))
      return -1;
    void* p = gptr(w, buf, len);
    if (!p && len) return -1;
    iov[i].iov_base = p;
    iov[i].iov_len = len;
  }
  return 0;
}

u32 w2c_wasi__snapshot__preview1_fd_read(W* w, u32 fd, u32 iovs_p, u32 n,
                                         u32 nread_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  struct iovec iov[64];
  if (iovs_to_host(w, iovs_p, n, iov, 64)) return WASI_EFAULT;
  ssize_t r = readv(e->host_fd, iov, (int)n);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u32(w, nread_p, (u32)r) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_write(W* w, u32 fd, u32 iovs_p, u32 n,
                                          u32 nwritten_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  struct iovec iov[64];
  if (iovs_to_host(w, iovs_p, n, iov, 64)) return WASI_EFAULT;
  ssize_t r = writev(e->host_fd, iov, (int)n);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u32(w, nwritten_p, (u32)r) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_pread(W* w, u32 fd, u32 iovs_p, u32 n,
                                          u64 off, u32 nread_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  struct iovec iov[64];
  if (iovs_to_host(w, iovs_p, n, iov, 64)) return WASI_EFAULT;
  ssize_t r = preadv(e->host_fd, iov, (int)n, (off_t)off);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u32(w, nread_p, (u32)r) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_pwrite(W* w, u32 fd, u32 iovs_p, u32 n,
                                           u64 off, u32 nwritten_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  struct iovec iov[64];
  if (iovs_to_host(w, iovs_p, n, iov, 64)) return WASI_EFAULT;
  ssize_t r = pwritev(e->host_fd, iov, (int)n, (off_t)off);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u32(w, nwritten_p, (u32)r) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_seek(W* w, u32 fd, u64 offset, u32 whence,
                                         u32 newoff_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  int wh;
  switch (whence) {
    case 0: wh = SEEK_SET; break;
    case 1: wh = SEEK_CUR; break;
    case 2: wh = SEEK_END; break;
    default: return WASI_EINVAL;
  }
  off_t r = lseek(e->host_fd, (off_t)(int64_t)offset, wh);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u64(w, newoff_p, (u64)r) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_tell(W* w, u32 fd, u32 off_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  off_t r = lseek(e->host_fd, 0, SEEK_CUR);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u64(w, off_p, (u64)r) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_sync(W* w, u32 fd) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  return fsync(e->host_fd) ? wasi_errno(errno) : 0;
}

u32 w2c_wasi__snapshot__preview1_fd_datasync(W* w, u32 fd) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
#ifdef F_FULLFSYNC
  /* fdatasync exists on darwin but fsync is the honest floor here */
  return fsync(e->host_fd) ? wasi_errno(errno) : 0;
#else
  return fdatasync(e->host_fd) ? wasi_errno(errno) : 0;
#endif
}

u32 w2c_wasi__snapshot__preview1_fd_advise(W* w, u32 fd, u64 off, u64 len,
                                           u32 advice) {
  (void)off; (void)len; (void)advice;
  return fd_get(w, fd) ? 0 : WASI_EBADF;
}

u32 w2c_wasi__snapshot__preview1_fd_allocate(W* w, u32 fd, u64 off, u64 len) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  struct stat st;
  if (fstat(e->host_fd, &st)) return wasi_errno(errno);
  off_t want = (off_t)(off + len);
  if (st.st_size < want && ftruncate(e->host_fd, want))
    return wasi_errno(errno);
  return 0;
}

u32 w2c_wasi__snapshot__preview1_fd_fdstat_get(W* w, u32 fd, u32 stat_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  uint8_t buf[24];
  memset(buf, 0, sizeof buf);
  buf[0] = e->filetype;
  uint16_t flags = e->fdflags;
  memcpy(buf + 2, &flags, 2);
  uint64_t rights = ~0ull; /* no capability model in this embedder */
  memcpy(buf + 8, &rights, 8);
  memcpy(buf + 16, &rights, 8);
  void* dst = gptr(w, stat_p, sizeof buf);
  if (!dst) return WASI_EFAULT;
  memcpy(dst, buf, sizeof buf);
  return 0;
}

u32 w2c_wasi__snapshot__preview1_fd_fdstat_set_flags(W* w, u32 fd, u32 flags) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  int fl = 0;
  if (flags & WASI_FDFLAG_APPEND) fl |= O_APPEND;
  if (flags & WASI_FDFLAG_NONBLOCK) fl |= O_NONBLOCK;
  if (fcntl(e->host_fd, F_SETFL, fl) < 0) return wasi_errno(errno);
  e->fdflags = (uint16_t)flags;
  return 0;
}

static void fill_filestat(uint8_t* buf, const struct stat* st) {
  memset(buf, 0, 64);
  u64 dev = (u64)st->st_dev, ino = (u64)st->st_ino;
  u64 nlink = (u64)st->st_nlink, size = (u64)st->st_size;
  u64 atim = (u64)st->st_atimespec.tv_sec * 1000000000ull + (u64)st->st_atimespec.tv_nsec;
  u64 mtim = (u64)st->st_mtimespec.tv_sec * 1000000000ull + (u64)st->st_mtimespec.tv_nsec;
  u64 ctim = (u64)st->st_ctimespec.tv_sec * 1000000000ull + (u64)st->st_ctimespec.tv_nsec;
  memcpy(buf + 0, &dev, 8);
  memcpy(buf + 8, &ino, 8);
  buf[16] = mode_to_filetype(st->st_mode);
  memcpy(buf + 24, &nlink, 8);
  memcpy(buf + 32, &size, 8);
  memcpy(buf + 40, &atim, 8);
  memcpy(buf + 48, &mtim, 8);
  memcpy(buf + 56, &ctim, 8);
}

u32 w2c_wasi__snapshot__preview1_fd_filestat_get(W* w, u32 fd, u32 stat_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  struct stat st;
  if (fstat(e->host_fd, &st)) return wasi_errno(errno);
  uint8_t buf[64];
  fill_filestat(buf, &st);
  void* dst = gptr(w, stat_p, sizeof buf);
  if (!dst) return WASI_EFAULT;
  memcpy(dst, buf, sizeof buf);
  return 0;
}

u32 w2c_wasi__snapshot__preview1_fd_filestat_set_size(W* w, u32 fd, u64 size) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  return ftruncate(e->host_fd, (off_t)size) ? wasi_errno(errno) : 0;
}

/* ---------------- prestat (preopen discovery) ---------------- */

u32 w2c_wasi__snapshot__preview1_fd_prestat_get(W* w, u32 fd, u32 prestat_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e || e->preopen < 0) return WASI_EBADF;
  const char* gp = w->preopens[e->preopen].guest_path;
  uint8_t buf[8];
  memset(buf, 0, sizeof buf);
  buf[0] = 0; /* preopentype::dir */
  u32 len = (u32)strlen(gp);
  memcpy(buf + 4, &len, 4);
  void* dst = gptr(w, prestat_p, sizeof buf);
  if (!dst) return WASI_EFAULT;
  memcpy(dst, buf, sizeof buf);
  return 0;
}

u32 w2c_wasi__snapshot__preview1_fd_prestat_dir_name(W* w, u32 fd, u32 path_p,
                                                     u32 path_len) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e || e->preopen < 0) return WASI_EBADF;
  const char* gp = w->preopens[e->preopen].guest_path;
  u32 len = (u32)strlen(gp);
  if (path_len < len) return WASI_EINVAL;
  void* dst = gptr(w, path_p, len);
  if (!dst) return WASI_EFAULT;
  memcpy(dst, gp, len);
  return 0;
}

/* ---------------- readdir ---------------- */

u32 w2c_wasi__snapshot__preview1_fd_readdir(W* w, u32 fd, u32 buf_p,
                                            u32 buf_len, u64 cookie,
                                            u32 used_p) {
  wasi_fd_entry* e = fd_get(w, fd);
  if (!e) return WASI_EBADF;
  int dup_fd = dup(e->host_fd);
  if (dup_fd < 0) return wasi_errno(errno);
  DIR* d = fdopendir(dup_fd);
  if (!d) {
    close(dup_fd);
    return wasi_errno(errno);
  }
  rewinddir(d);
  /* skip `cookie` entries (cookie = index of next entry) */
  for (u64 i = 0; i < cookie; i++) {
    if (!readdir(d)) break;
  }
  u32 used = 0;
  struct dirent* de;
  while ((de = readdir(d))) {
    u32 namlen = (u32)strlen(de->d_name);
    uint8_t head[24];
    memset(head, 0, sizeof head);
    u64 next = ++cookie;
    u64 ino = (u64)de->d_ino;
    memcpy(head + 0, &next, 8);
    memcpy(head + 8, &ino, 8);
    memcpy(head + 16, &namlen, 4);
    uint8_t ft = WASI_FT_UNKNOWN;
    if (de->d_type == DT_REG) ft = WASI_FT_REG;
    else if (de->d_type == DT_DIR) ft = WASI_FT_DIR;
    else if (de->d_type == DT_LNK) ft = WASI_FT_SYMLINK;
    else if (de->d_type == DT_CHR) ft = WASI_FT_CHAR;
    else if (de->d_type == DT_BLK) ft = WASI_FT_BLOCK;
    head[20] = ft;

    /* truncated tail entry signals "buffer full" to wasi-libc */
    u32 remain = buf_len - used;
    u32 copy_head = remain < 24 ? remain : 24;
    void* dst = gptr(w, buf_p + used, copy_head);
    if (!dst) { closedir(d); return WASI_EFAULT; }
    memcpy(dst, head, copy_head);
    used += copy_head;
    if (copy_head < 24) break;

    remain = buf_len - used;
    u32 copy_name = remain < namlen ? remain : namlen;
    dst = gptr(w, buf_p + used, copy_name);
    if (!dst && copy_name) { closedir(d); return WASI_EFAULT; }
    memcpy(dst, de->d_name, copy_name);
    used += copy_name;
    if (copy_name < namlen) break;
    if (used == buf_len) break;
  }
  closedir(d);
  return gwrite_u32(w, used_p, used) ? WASI_EFAULT : 0;
}

/* ---------------- path ops ---------------- */

u32 w2c_wasi__snapshot__preview1_path_open(W* w, u32 dirfd, u32 lookupflags,
                                           u32 path_p, u32 path_len,
                                           u32 oflags, u64 rights_base,
                                           u64 rights_inherit, u32 fdflags,
                                           u32 fd_p) {
  (void)rights_inherit;
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char path[1024];
  if (gpath(w, path_p, path_len, path, sizeof path)) return WASI_EFAULT;

  int flags = 0;
  bool want_read = (rights_base & WASI_RIGHT_FD_READ) != 0;
  bool want_write = (rights_base & WASI_RIGHT_FD_WRITE) != 0;
  if (want_read && want_write) flags = O_RDWR;
  else if (want_write) flags = O_WRONLY;
  else flags = O_RDONLY;

  if (oflags & WASI_O_CREAT) flags |= O_CREAT;
  if (oflags & WASI_O_DIRECTORY) flags |= O_DIRECTORY;
  if (oflags & WASI_O_EXCL) flags |= O_EXCL;
  if (oflags & WASI_O_TRUNC) flags |= O_TRUNC;
  if (fdflags & WASI_FDFLAG_APPEND) flags |= O_APPEND;
  if (fdflags & WASI_FDFLAG_NONBLOCK) flags |= O_NONBLOCK;
  if (fdflags & (WASI_FDFLAG_SYNC | WASI_FDFLAG_RSYNC)) flags |= O_SYNC;
  if (fdflags & WASI_FDFLAG_DSYNC) flags |= O_DSYNC;
  if (!(lookupflags & WASI_LOOKUP_SYMLINK_FOLLOW)) flags |= O_NOFOLLOW;

  int slot = fd_alloc(w);
  if (slot < 0) return WASI_EBADF;

  int hfd = openat(e->host_fd, path, flags, 0644);
  if (hfd < 0) {
    TRACE(w, "path_open(%u, \"%s\", o=%x) => errno %d", dirfd, path, oflags,
          errno);
    return wasi_errno(errno);
  }
  struct stat st;
  uint8_t ft = WASI_FT_UNKNOWN;
  if (!fstat(hfd, &st)) ft = mode_to_filetype(st.st_mode);
  fd_set_entry(w, slot, hfd, ft, (uint16_t)fdflags, -1);
  TRACE(w, "path_open(%u, \"%s\", o=%x) => fd %d", dirfd, path, oflags, slot);
  return gwrite_u32(w, fd_p, (u32)slot) ? WASI_EFAULT : 0;
}

u32 w2c_wasi__snapshot__preview1_path_filestat_get(W* w, u32 dirfd,
                                                   u32 lookupflags, u32 path_p,
                                                   u32 path_len, u32 stat_p) {
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char path[1024];
  if (gpath(w, path_p, path_len, path, sizeof path)) return WASI_EFAULT;
  struct stat st;
  int flags = (lookupflags & WASI_LOOKUP_SYMLINK_FOLLOW) ? 0 : AT_SYMLINK_NOFOLLOW;
  if (fstatat(e->host_fd, path, &st, flags)) return wasi_errno(errno);
  uint8_t buf[64];
  fill_filestat(buf, &st);
  void* dst = gptr(w, stat_p, sizeof buf);
  if (!dst) return WASI_EFAULT;
  memcpy(dst, buf, sizeof buf);
  return 0;
}

u32 w2c_wasi__snapshot__preview1_path_create_directory(W* w, u32 dirfd,
                                                       u32 path_p,
                                                       u32 path_len) {
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char path[1024];
  if (gpath(w, path_p, path_len, path, sizeof path)) return WASI_EFAULT;
  return mkdirat(e->host_fd, path, 0755) ? wasi_errno(errno) : 0;
}

u32 w2c_wasi__snapshot__preview1_path_remove_directory(W* w, u32 dirfd,
                                                       u32 path_p,
                                                       u32 path_len) {
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char path[1024];
  if (gpath(w, path_p, path_len, path, sizeof path)) return WASI_EFAULT;
  return unlinkat(e->host_fd, path, AT_REMOVEDIR) ? wasi_errno(errno) : 0;
}

u32 w2c_wasi__snapshot__preview1_path_unlink_file(W* w, u32 dirfd, u32 path_p,
                                                  u32 path_len) {
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char path[1024];
  if (gpath(w, path_p, path_len, path, sizeof path)) return WASI_EFAULT;
  return unlinkat(e->host_fd, path, 0) ? wasi_errno(errno) : 0;
}

u32 w2c_wasi__snapshot__preview1_path_rename(W* w, u32 old_dirfd, u32 old_p,
                                             u32 old_len, u32 new_dirfd,
                                             u32 new_p, u32 new_len) {
  wasi_fd_entry* eo = fd_get(w, old_dirfd);
  wasi_fd_entry* en = fd_get(w, new_dirfd);
  if (!eo || !en) return WASI_EBADF;
  char oldp[1024], newp[1024];
  if (gpath(w, old_p, old_len, oldp, sizeof oldp) ||
      gpath(w, new_p, new_len, newp, sizeof newp))
    return WASI_EFAULT;
  return renameat(eo->host_fd, oldp, en->host_fd, newp) ? wasi_errno(errno)
                                                        : 0;
}

u32 w2c_wasi__snapshot__preview1_path_symlink(W* w, u32 target_p, u32 target_len,
                                              u32 dirfd, u32 link_p,
                                              u32 link_len) {
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char target[1024], link[1024];
  if (gpath(w, target_p, target_len, target, sizeof target) ||
      gpath(w, link_p, link_len, link, sizeof link))
    return WASI_EFAULT;
  return symlinkat(target, e->host_fd, link) ? wasi_errno(errno) : 0;
}

u32 w2c_wasi__snapshot__preview1_path_readlink(W* w, u32 dirfd, u32 path_p,
                                               u32 path_len, u32 buf_p,
                                               u32 buf_len, u32 used_p) {
  wasi_fd_entry* e = fd_get(w, dirfd);
  if (!e) return WASI_EBADF;
  char path[1024];
  if (gpath(w, path_p, path_len, path, sizeof path)) return WASI_EFAULT;
  void* dst = gptr(w, buf_p, buf_len);
  if (!dst && buf_len) return WASI_EFAULT;
  ssize_t r = readlinkat(e->host_fd, path, dst, buf_len);
  if (r < 0) return wasi_errno(errno);
  return gwrite_u32(w, used_p, (u32)r) ? WASI_EFAULT : 0;
}

/* ---------------- poll ---------------- */

u32 w2c_wasi__snapshot__preview1_poll_oneoff(W* w, u32 in_p, u32 out_p,
                                             u32 nsubs, u32 nevents_p) {
  if (nsubs == 0) return WASI_EINVAL;
  /* The guest is single-threaded and its fds are plain files (always
   * ready). Strategy: emit ready events for every fd subscription; if
   * there are none, sleep for the shortest clock subscription and emit
   * its event. */
  u32 emitted = 0;
  int64_t min_sleep_ns = -1;
  u64 min_clock_userdata = 0;

  for (u32 i = 0; i < nsubs; i++) {
    u32 sub = in_p + i * 48;
    uint8_t* sp = gptr(w, sub, 48);
    if (!sp) return WASI_EFAULT;
    u64 userdata;
    memcpy(&userdata, sp, 8);
    uint8_t tag = sp[8];
    if (tag == WASI_EVENTTYPE_CLOCK) {
      u32 clock_id;
      u64 timeout;
      u16 flags;
      memcpy(&clock_id, sp + 16, 4);
      memcpy(&timeout, sp + 24, 8);
      memcpy(&flags, sp + 40, 2);
      int64_t rel_ns;
      if (flags & WASI_SUBCLOCKFLAGS_ABSTIME) {
        struct timespec ts;
        clock_gettime(clock_id == WASI_CLOCK_REALTIME ? CLOCK_REALTIME
                                                      : CLOCK_MONOTONIC,
                      &ts);
        u64 now = (u64)ts.tv_sec * 1000000000ull + (u64)ts.tv_nsec;
        rel_ns = timeout > now ? (int64_t)(timeout - now) : 0;
      } else {
        rel_ns = (int64_t)timeout;
      }
      if (min_sleep_ns < 0 || rel_ns < min_sleep_ns) {
        min_sleep_ns = rel_ns;
        min_clock_userdata = userdata;
      }
    } else if (tag == WASI_EVENTTYPE_FD_READ ||
               tag == WASI_EVENTTYPE_FD_WRITE) {
      /* regular files: always ready */
      uint8_t ev[32];
      memset(ev, 0, sizeof ev);
      memcpy(ev, &userdata, 8);
      /* error=0 */
      ev[10] = tag;
      u64 nbytes = 1 << 16;
      memcpy(ev + 16, &nbytes, 8);
      void* dst = gptr(w, out_p + emitted * 32, 32);
      if (!dst) return WASI_EFAULT;
      memcpy(dst, ev, 32);
      emitted++;
    }
  }

  if (emitted == 0 && min_sleep_ns >= 0) {
    if (min_sleep_ns > 0) {
      struct timespec ts = {(time_t)(min_sleep_ns / 1000000000ll),
                            (long)(min_sleep_ns % 1000000000ll)};
      nanosleep(&ts, NULL);
    }
    uint8_t ev[32];
    memset(ev, 0, sizeof ev);
    memcpy(ev, &min_clock_userdata, 8);
    ev[10] = WASI_EVENTTYPE_CLOCK;
    void* dst = gptr(w, out_p, 32);
    if (!dst) return WASI_EFAULT;
    memcpy(dst, ev, 32);
    emitted = 1;
  }
  return gwrite_u32(w, nevents_p, emitted) ? WASI_EFAULT : 0;
}
