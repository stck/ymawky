;; defs.S

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
.equ SYS_exit,       1
.equ SYS_fork,       2
.equ SYS_read,       3
.equ SYS_write,      4
.equ SYS_open,       5
.equ SYS_close,      6
.equ SYS_wait4,      7
.equ SYS_unlink,     10
.equ SYS_getpid,     20
.equ SYS_accept,     30
.equ SYS_munmap,     73
.equ SYS_setitimer,  83
.equ SYS_socket,     97
.equ SYS_bind,       104
.equ SYS_setsockopt, 105
.equ SYS_listen,     106
.equ SYS_rename,     128
.equ SYS_shutdown,   134
.equ SYS_mmap,       197
.equ SYS_lseek,      199
.equ SYS_stat64,     338

;; constants
.equ BUF_SIZE,       16384 ; number of bytes for read()

;; request type ids
.equ HEAD_REQ_ID,    0
.equ GET_REQ_ID,     1
.equ OPTIONS_REQ_ID, 2
.equ DELETE_REQ_ID,  3
.equ PUT_REQ_ID,     4

;; stuff for file.S
.equ S_IFREG,        0x8000
.equ S_IFDIR,        0x4000

;; errno values
.equ EPERM,          1
.equ ENOENT,         2
.equ EIO,            5
.equ ENOMEM,         12
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

;; oflags values for open()
.equ O_RDONLY,       0x0000
.equ O_WRONLY,       0x0001
.equ O_RDRW,         0x0002
.equ O_CREAT,        0x0200
.equ O_TRUNC,        0x0400
