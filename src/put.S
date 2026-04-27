;; put.S
;; PUT request handler. writes body to a temp file, then atomically renames
;; on success. uses setitimer + a custom SIGALRM handler to time out slow
;; clients (slowloris-style) during the body read.

#include "defs.S"

.global put

.data
.align 3
;; struct itimerval for setitimer()
put_read_timer:
    .quad 0 ; it_interval.tv_sec
    .long 0 ; it_interval.tv_usec
    .long 0 ; -- padding --

    .quad 0 ; it_value.tv_sec
    .long 0 ; it_value.tv_usec
    .long 0 ; -- padding --

.bss
.align 3
filename_tmp_str:     .skip 8
filename_tmp_len:     .skip 8

.text
.align 2

;; write content to a file descriptor, retrying in case of partial-writes.
;; input (same as write() syscall)
;; x0 -> file descriptor
;; x1 -> buffer
;; x2 -> nbytes
;;
;; output
;; x0 -> number of bytes written, total.
write_all:
    stp x25, x26, [sp, #-16]!
    mov x25, x0 ; save x0 into x20
    mov x26, #0
    ; carry = 0, in case we exit with cbz without ever calling write().
    adds xzr, xzr, xzr
1:
    cbz x2, 2f

    mov x16, SYS_write
    mov x0, x25
    ; x1 is set by caller
    ; x2 is also set by caller
    svc #0x80
    b.cs Lwrite_fail

    sub x2, x2, x0 ; subtract written bytes
    add x26, x26, x0 ; increment total bytes written
    add x1, x1, x0 ; increment pointer
    b 1b

2:
    mov x0, x26 ; return total bytes written

    ldp x25, x26, [sp], #16
    ret

Lwrite_fail:
    cmp x0, #EINTR
    b.eq 1b

    cmp xzr, xzr ; set C=1 so we can b.cs
    b 2b


;; handle "PUT /" method.
;; input
;; x0 -> header
;; x1 -> length of header
;;
;; uses from global registers
;; x23 -> index after header end in buf, after \r\n\r\n
;; x24 -> total bytes read. we can use this, along with content-length, to
;;        determine if more read() calls are needed.
;;
;; output
;; none, proc quits after handling.
put:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x25, x26, [sp, #48]

    mov x19, #0 ; was file created? #0 = no, file existed, #1 = yes, new file
    mov x21, x1
    mov x22, x0

    bl do_path_checks

    ldr_l x0, filename_str
    bl stat_path
    cbz x0, Ltarget_exists

    cmp x0, #ENOENT
    b.eq Ltarget_missing

    b handle_fs_error

Ltarget_exists:
    cb ne, w1, #S_IFREG, L403

    mov x19, #0
    b 0f

Ltarget_missing:
    mov x19, #1
    ;; fallthrough

0:

    mov x0, x22
    mov x1, x21
    bl parse_content_length
    b.cs Lpcl_error
    mov x21, x0 ;; save content-length in x21


1:
    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl make_tmp_file
    b.cs L500

    str_l x0, filename_tmp_str
    str_l x1, filename_tmp_len

    ; open(filename, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    mov x16, SYS_open
    ldr_l x0, filename_tmp_str
    mov x1, #O_WRONLY
    orr x1, x1, #O_CREAT
    orr x1, x1, #O_TRUNC
    orr x1, x1, #O_NOFOLLOW_ANY
    mov x2, #0644 ; rw-r--r--
    svc #0x80
    ;; ironically i can just branch to the stat failed label for open(), since
    ;; the errnos and their causes are largely the same.
    b.cs Lput_stat_failed
    mov x25, x0 ;; save fd into x25

    ;; x0 is already set
    bl stat_fd
    cbnz x0, Lput_stat_failed

    sub x22, x24, x23 ; x22 = x24 - x23, body bytes sitting in buf after header

    ;; write remaining body from buffer.
    mov x0, x25
    adr_l x1, buf
    add x1, x1, x23
    ;; get min(x22, x21). store in x2.
    cmp x22, x21
    csel x2, x22, x21, lo
    bl write_all
    b.cs L500
    sub x21, x21, x0
    cbz x21, Lput_done

    ;; calculate a timeout for read to try and prevent slowloris-like attacks
    ;; from slowly drip-drip-dripping content into a PUT and taking up
    ;; resources.
    ;; number of seconds = grace_period + content_length / min_bps
    ;; 5s + content_length / 4kb/s
    mov x1, #4096
    udiv x2, x21, x1 ;; x2 = content_length / min_bps
    add x2, x2, #5 ;; +5s grace

    ;; write the number of seconds calculated to the itimerval struct in the
    ;; it_value.tv_sec member
    adr_l x0, put_read_timer
    str x2, [x0, #16] ;; offset 16 = it_value.tv_sec

    ;; call setitimer
    mov x16, SYS_setitimer
    mov x0, #0 ; ITIMER_REAL
    adr_l x1, put_read_timer
    mov x2, #0
    svc #0x80

    ;; now SIGALRM will occur after that period of time. we gotta catch it!
    ;; NOTE sigaction is a bit odd on MacOS and different than Linux/POSIX.
    ;; POSIX: (http://git.musl-libc.org/cgit/musl/tree/include/signal.h#n169)
    ;;   struct sigaction {
    ;;       union {
    ;;           void (*sa_handler)(int);
    ;;           void (*sa_sigaction)(int, siginfo_t *, void *);
    ;;       } __sa_handler;
    ;;       sigset_t sa_mask;
    ;;       int sa_flags;
    ;;       void (*sa_restorer)(void);
    ;;   };
    ;;
    ;; Darwin: (https://github.com/apple/darwin-xnu/blob/2ff845c2e033bd0ff64b5b6aa6063a1f8f65aa32/bsd/sys/signal.h#L374-L379)
    ;;   struct  __sigaction {
    ;;     union __sigaction_u __sigaction_u;
    ;;	   void    (*sa_tramp)(void *, int, int, siginfo_t *, void *);
    ;;	   sigset_t sa_mask;
    ;;	   int     sa_flags;
    ;;   };
    ;; In POSIX systems, the kernel jumps directly to the handler. In Darwin
    ;; (MacOS), the kernel jumps first to sa_tramp. This is usually handled by
    ;; libc -- sa_tramp is responsible for calling your handler and then
    ;; executing the sigreturn syscall, which restores the thread's previous
    ;; state: registers, pc, sp, etc.
    ;; The sigaction syscall in Darwin requires this struct, including the
    ;; sa_tramp member. Since we aren't gonna be using libc, we can actually
    ;; do something kind of cool and instead use sa_tramp *as* the handler
    ;; itself, branching to 408 (Request Timeout).
    ;; We have to ensure that bytes 0-7 are not 0 or 1, however.
    ;; in bsd/kern/kern_sig.c, setsigvec() checks sa->sa_handler against a few
    ;; values. If sa_handler (bytes 0-7) is SIG_IGN (1LL), the signal is
    ;; ignored. If it's SIG_DFL (0LL), the program terminates by default.
    ;; If it's anything else, sa_tramp is executed which does kernel shit and
    ;; then executes the code sa_handler is pointing to, typically. In my code
    ;; though, it just does the handling itself.
    ;; https://github.com/opensource-apple/xnu/blob/0a798f6738bc1db01281fc08ae024145e84df927/bsd/kern/kern_sig.c#L643
    ;; HOWEVER!! Since we never call sigreturn or sigprocmask, and sp gets
    ;; fucked, we can never actually return to the main loop. if we do it
    ;; like this. Since a signal is blocked while it's being handled, SIGALRM
    ;; will be permanently blocked for the rest of this process's life, and it
    ;; won't fire again.
    ;; But that's really fine, if you think about it, since 408 sends the code
    ;; and closes clientfd, then exits. So it's not a problem. But something
    ;; to keep in mind.
    ;;
    ;; TL;DR: sigaction works differently in MacOS than Linux. this is janky
    ;; as fuck and hacky but also perfectly fine and good.
    ;; if you ever want to port ymawky to other systems, this is gonna be a
    ;; major difference.
    ;; set up the __sigaction struct
    adr_l x0, Lput_sigalrm_handler
    str x0, [sp, #0]  ; sa_handler
    str x0, [sp, #8]   ; sp_tramp = 408 handler. see bigass comment above.
    str wzr, [sp, #16] ; sa_mask = 0
    str wzr, [sp, #20] ; sa_flags = 0
    mov x16, SYS_sigaction
    mov w0, #SIGALRM
    mov x1, sp
    mov x2, #0 ; old action = NULL
    svc #0x80
    ;; if sigaction fails, it's due to some memory issue. that should always
    ;; be a 500. i don't want to just silently fail and let any connections go
    ;; un-timedout, so just throw a 500 and take the shit.
    b.cs L500

    mov x22, #BUF_SIZE ; from defs.S, 16KB
Lput_readwrite_loop:
    cbz x21, Lput_done

    mov x16, SYS_read
    ldr_l x0, clientfd
    adr_l x1, buf
    cmp x22, x21
    csel x2, x22, x21, lo
    svc #0x80
    b.cs Lput_read_failed

    ;; now x0 contains bytes read
    mov x26, x0
    sub x21, x21, x0

    mov x2, x0
    adr_l x1, buf
    mov x0, x25
    bl write_all
    b.cs L500

    ;; did we read 0 bytes? we're done if so. should this be b.lo? i'd like it
    ;; to be less than or equal, but i believe lo is just less-than. maybe 2
    ;; cmps? like cmp #0, b.eq, and b.lo? 
    cbz x26, Lput_read_zero

    b Lput_readwrite_loop

Lput_read_failed:
    cmp x0, #EAGAIN
    b.eq L408
    ;; fallthrough
Lput_close_and_500:
    ;; close and delete the temporary file
    mov x16, SYS_close
    mov x0, x25
    svc #0x80

    mov x16, SYS_unlink
    ldr_l x0, filename_tmp_str
    svc #0x80

    b reply_500

Lput_sigalrm_handler:
    mov x16, SYS_close
    mov x0, x25
    svc #0x80

    mov x16, SYS_unlink
    ldr_l x0, filename_tmp_str
    svc #0x80

    b reply_408


;; if we read 0 bytes, check if we were actually done reading. if
;; content-length bytes had not been read total, the client hung up in the
;; middle. if that happens, check if we created a new file. if we did, unlink
;; it so we don't have half-written garbage.
Lput_read_zero:
    cbnz x21, 3f

    ;; yeah if content-length is actually 0 now, we're all good.
    b Lput_done
3:
    cbz x19, 4f ; if no file was created, just reply 400
    mov x16, SYS_unlink
    ldr_l x0, filename_tmp_str
    svc #0x80
4:
    b L400

Lput_done:
    mov x16, SYS_close
    mov x0, x25
    svc #0x80

    mov x16, SYS_renameatx_np
    mov x0, #AT_FDCWD
    ldr_l x1, filename_tmp_str
    mov x2, #AT_FDCWD
    ldr_l x3, filename_str
    mov x4, #RENAME_NOFOLLOW_ANY
    svc #0x80
    b.cs Lhfs_err

    cbnz x19, L201
    b L204

;; if stat failed due to ENOENT, that's fine -- just mark that the file doesn't
;; exist yet. otherwise, branch to handle_fs_error, which will branch to the
;; relevant http response.
Lput_stat_failed:
    cmp x0, #ENOENT
    b.ne 2f

    ;; set x19 to 1 so we know a new file was created.
    mov x19, #1
    b 1b
;; stat failed for some reason other than ENOENT.
2:
    cbz x25, 3f

    ;; save errno from fstat64() in x1.
    mov x1, x0

    mov x16, SYS_close
    mov x0, x25
    svc #0x80
    ;; restore fstat64()'s errno, in case close() also had an error lol
    mov x0, x1
3:
    b handle_fs_error

;; couldn't parse content length. if x0 is 1, it's a bad request. if x0 is 0,
;; no content length was actually provided.
Lpcl_error:
    cmp x0, #1
    b.eq L400
    cmp x0, #0
    b.eq L411
    cmp x0, #2
    b.eq L413

    ;; should never reach here. but just in case!
    b L500

put_epilogue:
    ldp x25, x26, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    b child_end


;; trampolines for conditional branches across files.
L201: b reply_201
L204: b reply_204
L400: b reply_400
L403: b reply_403
L408: b reply_408
L411: b reply_411
L413: b reply_413
L500: b reply_500
Lhfs_err: b handle_fs_error
