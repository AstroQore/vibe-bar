#include "VibeBarPOSIX.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <sys/wait.h>
#include <unistd.h>

int vb_open_directory_nofollow(const char *absolute_path) {
  if (absolute_path == NULL || absolute_path[0] != '/') {
    errno = EINVAL;
    return -1;
  }
  int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
  if (current < 0)
    return -1;
  char *copy = strdup(absolute_path);
  if (copy == NULL) {
    close(current);
    errno = ENOMEM;
    return -1;
  }
  char *save = NULL;
  for (char *part = strtok_r(copy, "/", &save); part != NULL;
       part = strtok_r(NULL, "/", &save)) {
    if (strcmp(part, ".") == 0 || strcmp(part, "..") == 0) {
      free(copy);
      close(current);
      errno = EINVAL;
      return -1;
    }
    int next =
        openat(current, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (next < 0) {
      int code = errno;
      free(copy);
      close(current);
      errno = code;
      return -1;
    }
    close(current);
    current = next;
  }
  free(copy);
  return current;
}

int vb_mkdirat_private(int parent_fd, const char *name) {
  if (mkdirat(parent_fd, name, 0700) == 0 || errno == EEXIST)
    return 0;
  return -1;
}

int vb_openat_directory_nofollow(int parent_fd, const char *name) {
  return openat(parent_fd, name,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
}

int vb_openat_lock_nofollow(int parent_fd, const char *name) {
  return openat(parent_fd, name, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                0600);
}

int vb_openat_read_nofollow(int parent_fd, const char *name) {
  return openat(parent_fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
}

int vb_openat_new_private(int parent_fd, const char *name) {
  return openat(parent_fd, name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
}

int vb_flock_shared_nonblocking(int fd) { return flock(fd, LOCK_SH | LOCK_NB); }
int vb_flock_exclusive_nonblocking(int fd) {
  return flock(fd, LOCK_EX | LOCK_NB);
}
int vb_flock_unlock(int fd) { return flock(fd, LOCK_UN); }

int vb_fd_identity(int fd, uint64_t *device, uint64_t *inode) {
  struct stat info;
  if (fstat(fd, &info) != 0)
    return -1;
  *device = (uint64_t)info.st_dev;
  *inode = (uint64_t)info.st_ino;
  return 0;
}
int vb_fd_is_owned_single_link_regular(int fd) {
  struct stat info;
  return fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_nlink == 1 &&
         info.st_uid == geteuid();
}

int vb_is_symlink_at(int parent_fd, const char *name) {
  struct stat info;
  if (fstatat(parent_fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0)
    return -1;
  return S_ISLNK(info.st_mode) ? 1 : 0;
}

int vb_renameat_same_directory(int directory_fd, const char *from,
                               const char *to) {
  return renameat(directory_fd, from, directory_fd, to);
}

int vb_unlinkat_file(int directory_fd, const char *name) {
  return unlinkat(directory_fd, name, 0);
}
int vb_write_bytes(int fd, const void *bytes, int length) {
  return (int)write(fd, bytes, (size_t)length);
}
static int vb_fail_fsync_after = 0;
int vb_fsync_fd(int fd) {
  if (vb_fail_fsync_after > 0 && --vb_fail_fsync_after == 0) {
    errno = EIO;
    return -1;
  }
  return fsync(fd);
}
void vb_test_fail_fsync_after(int calls) { vb_fail_fsync_after = calls; }
int vb_fchmod_private(int fd) { return fchmod(fd, 0600); }
int vb_fchmod_directory(int fd) { return fchmod(fd, 0700); }

int vb_test_child_cannot_flock(const char *path) {
  pid_t child = fork();
  if (child < 0)
    return -1;
  if (child == 0) {
    int fd = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0)
      _exit(2);
    int result = flock(fd, LOCK_EX | LOCK_NB);
    int code =
        (result < 0 && (errno == EWOULDBLOCK || errno == EAGAIN)) ? 0 : 1;
    close(fd);
    _exit(code);
  }
  int status = 0;
  if (waitpid(child, &status, 0) < 0)
    return -1;
  return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 1;
}

int vb_test_child_lock_pair(const char *barrier, const char *store,
                            int barrier_exclusive) {
  pid_t child = fork();
  if (child < 0)
    return -1;
  if (child == 0) {
    int b = open(barrier, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    int s = open(store, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    if (b < 0 || s < 0)
      _exit(2);
    int first = flock(b, (barrier_exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB);
    int second = first == 0 ? flock(s, LOCK_EX | LOCK_NB) : -1;
    int code = first == 0 && second == 0
                   ? 0
                   : ((errno == EWOULDBLOCK || errno == EAGAIN) ? 1 : 2);
    close(s);
    close(b);
    _exit(code);
  }
  int status = 0;
  if (waitpid(child, &status, 0) < 0)
    return -1;
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}
