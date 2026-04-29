;; get.S
;; GET (and HEAD) request handler

#include "defs.S"

.global get
.global head

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
header_len:  .skip 8

.text
.align 2

;; build a header, store it into header_buf, and then write it to the socket
;; in a loop, accounting for partial-writes.
;; input
;; x0 -> file length
;;
;; output
;; x0 -> header buffer
;; x1 -> header length
build_header:
    stp x29, x30, [sp, #-32]!
    str x20, [sp, #16]
    mov x20, x0

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

    mov x0, x20
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

    b Lbh_done
Lheader_too_big:
    mov x0, #0
    str_l x0, header_len
    cmp xzr, xzr ; set carry
    b Lbh_epilogue

Lbh_done:
    str_l x14, header_len
    cmn xzr, xzr ; clear carry
    b Lbh_epilogue

Lbh_epilogue:
    ldr x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret


;; setup for the "GET" and "HEAD" methods. pretty much just writes the header
;; after getting content length and such.
;; none, uses .bss data
;;
;; output
;; x0 -> length of file
;; NOTE this function opens a file and doesn't close it -- it saves the open
;; file descriptor in .bss, file_des. be sure to close it!
get_setup:
    stp x29, x30, [sp, #-32]!
    str x20, [sp, #16]

    mov x0, #1 ;; yes, default to index.html if no file is given
    bl do_path_checks
    ldr_l x0, filename_str

    mov x16, SYS_open
    ldr_l x0, filename_str
    mov x1, #0 ; RDONLY
    orr x1, x1, #O_NOFOLLOW_ANY
    svc #0x80
    b.cs Lhfs_err ; if the carry flag is set, open() failed so handle it

    ;; save the file descriptor
    str_l x0, file_des

    bl stat_fd
    cbnz x0, Lhfs_err
    cmp w1, #S_IFREG
    b.ne L403

    ; x2 should be the file length from fstat64(). store it in x20
    mov x0, x2
    mov x20, x2
    bl build_header
    ;; if build_header set carry, that means header was too large for some
    ;; reason. 500.
    b.cs L500

    ;; if it returned 0 it's good :3
    ;; save x0 (header buffer) and x1 (header len) for use later
    b Lgs_epilogue

Lgs_epilogue:
    mov x0, x20

    ldr x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret


;; for HEAD, reply with just the header. pretty short n sweet.
head:
    bl get_setup ;; this does basically everything we want.

    ldr_l x0, clientfd
    adr_l x1, header_buf
    ldr_l x2, header_len
    bl write_all
    ;; it's ok to ignore write errors here, since if we get an error the way to
    ;; handle it would be to close the file descriptor and b child_end, which
    ;; is what we're doing here anyway. can't write 500 Internal Server Error
    ;; in the middle of another header, lol.

    ;; we really just gotta close the file and exit
    mov x16, SYS_close
    ldr_l x0, file_des
    svc #0x80
    b child_end


;; do the "GET /" stuff."
get:
    bl get_setup

    ;; if the file is 0 bytes long, let's skip the mmap and all that. just
    ;; close the file. x0 from get_setup
    cbz x0, Lget_end

    ;; let's save file length into x13! please? we need to use it but only in
    ;; this func -- i really don't wanna do more stack shit here...
    mov x13, x0

    ; mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
    mov x16, SYS_mmap
    mov x0, #0
    mov x1, x13
    mov x2, #1 ; PROT_READ
    mov x3, #2 ; MAP_PRIVATE
    ldr_l x4, file_des ; file descriptor
    mov x5, #0 ; offset
    svc #0x80
    b.cs Lget_end
    ;; x0 is now the pointer to memory for the file

    ;; stash the pointer somewhere safe
    mov x12, x0

    ldr_l x0, clientfd
    adr_l x1, header_buf
    ldr_l x2, header_len
    bl write_all
    b.cs 2f ; if header write failed, don't bother writing the body

    ;; x12 -> pointer to mmap'd memory
    ;; x13 -> total length of file
    ldr_l x0, clientfd
    mov x1, x12
    mov x2, x13
    bl write_all
2:
    b Lwrite_done

Lwrite_done:
    mov x16, SYS_munmap
    mov x0, x12
    mov x1, x13
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
L500: b reply_500
Lhfs_err: b handle_fs_error
