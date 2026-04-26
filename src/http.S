#include "defs.S"

.global get
.global put
.global delete
.align 4

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

head_response:
    .ascii "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
.equ head_response_len, . - head_response

head_content_type:
    .ascii "\r\nContent-Type: "
.equ head_content_type_len, . - head_content_type

good_response_tail:
    .ascii "\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nServer: ymawky\r\n\r\n"
.equ good_response_tail_len, . - good_response_tail

.bss
file_des:             .skip 8
filename_str:         .skip 8
filename_len:         .skip 8
filename_tmp_str:     .skip 8
filename_tmp_len:     .skip 8
file_contents:        .skip 8
file_length:          .skip 8
content_length_str:   .skip 8
content_length_len:   .skip 8
.equ header_buf_size, 512
header_buf:           .skip header_buf_size

.text
;; build a header, store it into header_buf, and then write it to the socket
;; in a loop, accounting for partial-writes.
;; input
;; none i believe, it uses data in .bss
;;
;; output
;; x0 -> 0 on success, 1 if write() failed, 2 if resulting header would be
;;       too large.
write_header:
    stp x29, x30, [sp, #-16]!

    adr_l x13, header_buf
    mov x14, #0 ; counter of bytes writteen to header_buf

    ;; copy "HTTP/1.1 200 OK...", beginning of header, to header_buf
    mov x0, x13
    adr_l x1, head_response
    mov x2, head_response_len
    ;; make sure we don't write past header_buf's memory!
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0 ;; store header_buf + offset, memcpy increments the pointer

    ;; get file-length (stored in x21 register in get, which is hack-y.
    ;; fixme in the future!!
    mov x0, x21
    bl itoa

    ;; copy content-length string into header_buf
    mov x2, x1  ; content_length_len (length of string)
    mov x1, x0  ; content_length_str
    mov x0, x13 ; header_buf + offset
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

    ;; copy "\r\nContent-Type:" to buffer
    ; x0 is already set from previous memcpy
    adr_l x1, head_content_type
    mov x2, head_content_type_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl get_filetype

    ;; write filename to header_buf
    mov x2, x1 ; filename_len
    mov x1, x0 ; source string, filename_str
    mov x0, x13 ; destination, header_buf
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

    ;; write the \r\n\r\n
    ; x0 is still set from memcpy
    adr_l x1, good_response_tail
    mov x2, good_response_tail_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

    adr_l x10, header_buf ; beginning of header_buf
    ;; fall through to head_write_loop
Lhead_write_loop:
    ;; if we have 0 (or fewer) bytes remaining, skip to the end of the write
    ;; loop.
    cbz x14, Lhead_write_done

    ;; write(clientfd, mmap_ptr, size)
    mov x16, SYS_write
    ldr_l x0, clientfd
    mov x1, x10
    mov x2, x14
    svc #0x80
    b.cs Lhead_write_failed

    ; x0 -> bytes written
    add x10, x10, x0 ; advance the pointer by x0 bytes
    sub x14, x14, x0 ; and decrease remaining bytes by x0 bytes
    b Lhead_write_loop

Lhead_write_done:
    mov x0, #0
    b 1f
Lhead_write_failed:
    mov x0, #1
    b 1f
Lheader_too_big:
    mov x0, #2
    b 1f
1:
    ldp x29, x30, [sp], #16
    ret

;; decode hex/safety check/traversal check for a given path.
;; input
;; none, uses data from .bss
;;
;; output
;; none -- responds with 400 or other error codes if needed.
do_path_checks:
    stp x29, x30, [sp, #-16]!

    adr_l x0, buf
    bl parse_path
    b.cs Lpp_fail

    ;; x0 is already path, x1 is already path length
    bl decode_url
    cbz x0, L400

    str_l x0, filename_str
    str_l x1, filename_len
    bl check_path_safety
    cbz x0, L400

    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl check_path_traversal
    cbz x0, L400

    ldr_l x0, filename_len
    ldr_l x1, tmp_prefix_len_val
    cmp x0, x1
    b.lt 2f

    ldr_l x0, filename_str
    adr_l x1, tmp_prefix
    ldr_l x2, tmp_prefix_len_val
    bl streqn
    cbnz x0, L403
2:
    ldp x29, x30, [sp], #16
    ret

Lpp_fail:
    cbz x0, L400

    ;; TODO -- this check is reduntant. parse_path has a reduntant check if
    ;; the path starts with .ymawky_tmp_*, but that's a mistake, since it
    ;; could be encoded with %. so i've moved the check to this function, now
    ;; it's unneeded in parse_path.
    cmp x0, #1
    b.eq L403

    ;; this shouldn't be possible -- x0 should either be only 0 or 1. if it's
    ;; neither, something went wrong and it's my fault, personally.
    b L500

;; handler function for fstat64() failing. route to the proper HTTP reponse
;; based on errno.
;; input
;; x0 -> errno
;;
;; output
;; none, branches to reply_* and quits.
handle_fs_error:
    cb eq, x0, #ENAMETOOLONG, L414
    cb eq, x0, #EINVAL, L400
    ;; 403 since it's caused by O_NOFOLLOW_ANY most likely. if we ever allow
    ;; symlinks, NOTE this should be 508.
    cb eq, x0, #ELOOP, L403
    cb eq, x0, #ENOTDIR, L404
    cb eq, x0, #ENOENT, L404
    cb eq, x0, #EACCES, L403
    cb eq, x0, #EPERM, L403
    cb eq, x0, #EROFS, L403
    cb eq, x0, #EISDIR, L403
    cb eq, x0, #EFAULT, L500
    cb eq, x0, #EBUSY, L409
    cb eq, x0, #ENOTEMPTY, L409
    cb eq, x0, #ENOSPC, L507
    cb eq, x0, #EDQUOT, L507
    cb eq, x0, #EFBIG, L413

    b reply_500

;; handle "DELETE /" method.
;; input
;; none, uses .bss data
;;
;; output
;; none, replies either 204 or some error code and quits.
delete:
    bl do_path_checks
    ldr_l x0, filename_str

    bl stat_path
    cbnz x0, Ldelete_stat_failed
    cb ne, w1, #S_IFREG, L403

    mov x16, SYS_unlink
    ldr_l x0, filename_str
    svc #0x80
    b.cs Lunlink_failed

    b reply_204

;; these are really the same case, tbqh. the errno checks are the same. i use
;; different label names for clarity when reading hehe
Ldelete_stat_failed:
Lunlink_failed:
    ;; if the file doesn't exist (or was previously deleted), just reply 204
    ;; since DELETE is idempotent.
    cb eq, x0, #ENOENT, L204

    ;; if it's a dir, say it's not allowed. this could be 405, but i don't
    ;; want to build Allow: headers properly, lol. at least yet.
    cb eq, x0, #EISDIR, L403
    ;; other various 403s.
    cb eq, x0, #EACCES, L403
    cb eq, x0, #EPERM, L403
    cb eq, x0, #EROFS, L403
    ;; file is busy/conflict
    cb eq, x0, #EBUSY, L409

    ;; just default to 500
    b reply_500

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
bp1:

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
    b.cs handle_fs_error

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


;; handle "GET /" method.
;; input
;; none, uses .bss data
;;
;; output
;; none, proc quits after handling.
get:
    bl do_path_checks
    ldr_l x0, filename_str

    mov x16, SYS_open
    ldr_l x0, filename_str
    mov x1, #0 ; RDONLY
    orr x1, x1, #O_NOFOLLOW_ANY
    svc #0x80
    b.cs L404 ; if the carry flag is set, open() failed so 404

    ;; save the file descriptor
    str_l x0, file_des

    bl stat_fd
    cbnz x0, handle_fs_error
    cmp w1, #S_IFREG
    b.ne L403

    mov x21, x2 ; x2 should be the file length from fstat64(). store it in x21

    bl write_header

    ;; if write_header returned 2, that means header was too large for some
    ;; reason. 500.
    cmp x0, #2
    b.eq L500
    ;; otherwise if it's 1, that means a write failed somewhere. just give up
    cmp x0, #1
    b.eq Lget_end ; wire broke :(
    ;; if it returned 0 it's good :3

    ;; if it's a HEAD request, we just want to output the header, which we've
    ;; done, so jump to the end
    cmp x20, HEAD_REQ_ID
    b.eq Lget_end

    ;; if the file is 0 bytes long, let's skip the mmap and all that. just
    ;; close the file.
    cbz x21, Lget_end

    ; mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
    mov x16, SYS_mmap
    mov x0, #0
    mov x1, x21
    mov x2, #1 ; PROT_READ
    mov x3, #2 ; MAP_PRIVATE
    ldr_l x4, file_des ; file descriptor
    mov x5, #0 ; offset
    svc #0x80
    b.cs Lget_end
    ;; x0 is now the pointer to memory for the file

    ;; stash the pointer somewhere safe
    mov x12, x0

    ;; x12 -> pointer to mmap'd memory
    ;; x21 -> total length of file
    mov x10, x12  ; current position
    mov x11, x21 ; remaining bytes
Lwrite_loop:
    ;; if we have 0 (or fewer) bytes remaining, skip to the end of the write
    ;; loop.
    cbz x11, Lwrite_done

    ;; write(clientfd, mmap_ptr, size)
    mov x16, SYS_write
    ldr_l x0, clientfd
    mov x1, x10
    mov x2, x11
    svc #0x80
    b.cs Lwrite_done ;; uh oh something went wrong, we gotta mmunmap the file
            ;; and stuff now.

    ; x0 -> bytes written
    add x10, x10, x0 ; advance the pointer by x0 bytes
    sub x11, x11, x0 ; and decrease remaining bytes by x0 bytes
    b Lwrite_loop

Lwrite_done:
    mov x16, SYS_munmap
    mov x0, x12
    mov x1, x21
    svc #0x80
    ;; if munmap fails, b.cs would just branch to Lget_end anyway. so just
    ;; fall through either way.

;; close the file
Lget_end:
    mov x16, SYS_close
    ldr_l x0, file_des
    svc #0x80

1:
    b child_end

;; i can't cmp xN, xN; b.eq reply_*, since reply_* are in other files. it's
;; too far for conditional branching. so, i've gotta have these private labels
;; so i can conditionally branch.
L201: b reply_201
L204: b reply_204
L400: b reply_400
L403: b reply_403
L404: b reply_404
L408: b reply_408
L409: b reply_409
L411: b reply_411
L413: b reply_413
L414: b reply_414
L500: b reply_500
L507: b reply_507
L508: b reply_508
