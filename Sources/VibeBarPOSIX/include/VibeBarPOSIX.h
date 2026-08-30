#ifndef VIBE_BAR_POSIX_H
#define VIBE_BAR_POSIX_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

int vb_open_directory_nofollow(const char *absolute_path);
int vb_mkdirat_private(int parent_fd, const char *name);
int vb_openat_directory_nofollow(int parent_fd, const char *name);
int vb_openat_lock_nofollow(int parent_fd, const char *name);
int vb_openat_new_private(int parent_fd, const char *name);
int vb_flock_shared_nonblocking(int fd);
int vb_flock_exclusive_nonblocking(int fd);
int vb_flock_unlock(int fd);
int vb_fd_identity(int fd, uint64_t *device, uint64_t *inode);
int vb_fd_is_regular(int fd);
int vb_is_symlink_at(int parent_fd, const char *name);
int vb_renameat_same_directory(int directory_fd, const char *from,
                               const char *to);
int vb_unlinkat_file(int directory_fd, const char *name);
int vb_write_bytes(int fd, const void *bytes, int length);
int vb_fsync_fd(int fd);
void vb_test_fail_fsync_after(int calls);
int vb_fchmod_private(int fd);
int vb_fchmod_directory(int fd);
int vb_test_child_cannot_flock(const char *path);
int vb_test_child_lock_pair(const char *barrier, const char *store,
                            int barrier_exclusive);
#ifdef __cplusplus
}
#endif
#endif
