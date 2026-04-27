;; get.S
;; GET (and HEAD) request handler. shares its entry point with HEAD via
;; the request type id in x20: HEAD just skips the body-write step.

#include "defs.S"

.global get

.data
.align 3

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
.align 3
file_des:    .skip 8
.equ header_buf_size, 512
header_buf:  .skip header_buf_size

.text
.align 2

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
    cbnz x0, Lhfs_err
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


;; trampolines for conditional branches to reply_* / handle_fs_error in other
;; files (b.cond / cbz can't reach across files; unconditional b can).
L403: b reply_403
L404: b reply_404
L500: b reply_500
Lhfs_err: b handle_fs_error
