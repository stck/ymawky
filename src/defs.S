#include "config.S"

;; macros
;; turn adrp ... add ... into one call, adrl_l
.macro adr_l, reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

;; same with adrp ... (add ...) ldr ...
.macro ldr_l reg, sym
    adrp \reg, \sym@PAGE
    ldr \reg, [\reg, \sym@PAGEOFF]
.endm

;; and adrp ... (add ...) str ...
.macro str_l src, sym, scratch=x9
    adrp \scratch, \sym@PAGE
    str \src, [\scratch, \sym@PAGEOFF]
.endm

;; (c)ompare and (b)ranch, (eq/ne/gt/etc), x0, x1, label
.macro cb cond, r1, r2, l
    cmp \r1, \r2
    b.\cond \l
.endm

;; syscalls
.equ SYS_exit,         1
.equ SYS_fork,         2
.equ SYS_read,         3
.equ SYS_write,        4
.equ SYS_open,         5
.equ SYS_close,        6
.equ SYS_wait4,        7
.equ SYS_unlink,       10
.equ SYS_getpid,       20
.equ SYS_accept,       30
.equ SYS_sigaction,    46
.equ SYS_munmap,       73
.equ SYS_setitimer,    83
.equ SYS_socket,       97
.equ SYS_bind,         104
.equ SYS_setsockopt,   105
.equ SYS_listen,       106
.equ SYS_shutdown,     134
.equ SYS_mmap,         197
.equ SYS_proc_info,    336
.equ SYS_stat64,       338
.equ SYS_fstat64,      339
.equ SYS_getdirentries64, 344
.equ SYS_unlinkat,     472
.equ SYS_renameatx_np, 488

;; stuff for getdirentries64
;; dir entry buffer struct
.equ OFF_D_INTO,    0  ; load with ldr
.equ OFF_D_SEEKOFF, 8  ; load with ldr
.equ OFF_D_RECLEN,  16 ; load with ldrh
.equ OFF_D_NAMLEN,  18 ; load with ldrh
.equ OFF_D_TYPE,    20 ; load with ldrb
.equ OFF_D_NAME,    21 ; load with add xN, x19, #OFF_D_NAME
.equ DT_DIR,        4

;; proc stuff
.equ PROC_INFO_CALL_LISTPIDS, 1
.equ PROC_PPID_ONLY,          6

;; constants
.equ BUF_SIZE,       16384 ; number of bytes for read()

;; stuff for file.S
.equ S_IFREG,        0x8000
.equ S_IFDIR,        0x4000

;; errno values
.equ EPERM,          1
.equ ENOENT,         2
.equ EACCES,         13
.equ EFAULT,         14
.equ EBUSY,          16
.equ ENOTDIR,        20
.equ EISDIR,         21
.equ EROFS,          30
.equ ECONNABORTED,   53
.equ ECONNRESET,     54
.equ ETIMEDOUT,      60
.equ ELOOP,          62
.equ ENAMETOOLONG,   63
.equ EPIPE,          32
.equ ENETDOWN,       50
.equ ENETUNREACH,    51
.equ ENETRESET,      52
.equ EHOSTDOWN,      64
.equ EHOSTUNREACH,   65
.equ EAGAIN,         35
.equ EINTR,          4
.equ EFBIG,          27
.equ EDQUOT,         69 ; nice
.equ ENOSPC,         28
.equ ENOTEMPTY,      66
.equ EINVAL,         22

;; signals
.equ SIGALRM,        14
.equ SIGCHLD,        20
.equ SIG_IGN,        1
.equ SA_NOCLDWAIT,   0x0020

;; oflags values for open()
.equ O_RDONLY,       0x0000
.equ O_WRONLY,       0x0001
.equ O_CREAT,        0x0200
.equ O_TRUNC,        0x0400
.equ O_NOFOLLOW_ANY, 0x20000000

;; stuff for renameatx_np() and unlinkat()
.equ RENAME_NOFOLLOW_ANY, 0x00000010
.equ AT_SYMLINK_NOFOLLOW_ANY, 0x0800
.equ AT_FDCWD, -2
