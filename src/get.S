;; get.S
;; GET (and HEAD) request handler

#include "defs.S"

.global get
.global head

.data
.align 3

head_200:
    .ascii "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
.equ head_200_len, . - head_200

head_206:
    .ascii "HTTP/1.1 206 Partial Content\r\nConnection: close\r\nContent-Length: "
.equ head_206_len, . - head_206

head_content_range:
    .ascii "\r\nContent-Range: bytes "
.equ head_content_range_len, . - head_content_range

head_content_type:
    .ascii "\r\nContent-Type: "
.equ head_content_type_len, . - head_content_type

good_response_tail:
    .ascii "\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n\r\n"
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
;; x1 -> start range (or -1 if no range)
;; x2 -> end range
;;
;; output
;; x0 -> header buffer
;; x1 -> header length
build_header:
    stp x29, x30, [sp, #-48]!
    stp x20, x21, [sp, #16]
    stp x22, x23, [sp, #32]

    mov x20, x0
    mov x22, x1 ; start range
    mov x23, x2 ; end range

    adr_l x13, header_buf
    mov x14, #0 ; counter of bytes writteen to header_buf

    cmn x1, #1
    b.eq Lbh_200

    ;; 206 path
    ;; copy "HTTP/1.1 206 ...", beginning of header, to header_buf
    mov x0, x13
    adr_l x1, head_206
    mov x2, head_206_len
    ;; make sure we don't write past header_buf's memory!
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0 ;; store header_buf + offset, memcpy increments the pointer

    b Lbh_content_length

Lbh_200:
    ;; copy "HTTP/1.1 200 OK...", beginning of header, to header_buf
    mov x0, x13
    adr_l x1, head_200
    mov x2, head_200_len
    ;; make sure we don't write past header_buf's memory!
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0 ;; store header_buf + offset, memcpy increments the pointer

Lbh_content_length:
    cmn x22, #1
    b.eq 1f

    ;; if we're sending a range, content-length should be end - start instead
    sub x0, x23, x22
    add x0, x0, #1
    b 2f

1:
    ;; but if it's just a file, just grab the total file length.
    mov x0, x20

2:
    bl itoa
    ;; copy content-length string into header_buf
    mov x2, x1  ; content_length_len (length of string)
    mov x1, x0  ; content_length_str
    mov x0, x13 ; header_buf + offset
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

    ;; skip all this stuff for no range
    cmn x22, #1
    b.eq Lbh_content_type

    ;; 206 path
    ;; write Content-Range: bytes
    adr_l x1, head_content_range
    mov x2, head_content_range_len
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    ;; start range
    mov x0, x22
    bl itoa

    mov x2, x1
    mov x1, x0
    mov x0, x13
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    ;; -
    add x14, x14, #1
    cb gt, x14, header_buf_size, Lheader_too_big
    mov w0, #'-'
    strb w0, [x13]
    add x13, x13, #1

    ;; end range
    mov x0, x23
    bl itoa

    mov x2, x1
    mov x1, x0
    mov x0, x13
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy
    mov x13, x0

    ;; /
    add x14, x14, #1
    cb gt, x14, header_buf_size, Lheader_too_big
    mov w0, #'/'
    strb w0, [x13]
    add x13, x13, #1

    ;; total size
    mov x0, x20
    bl itoa

    mov x2, x1  ; content_length_len (length of string)
    mov x1, x0  ; content_length_str
    mov x0, x13 ; header_buf + offset
    add x14, x14, x2
    cb gt, x14, header_buf_size, Lheader_too_big
    bl memcpy

Lbh_content_type:
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
    ldp x22, x23, [sp, #32]
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #48
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
    stp x29, x30, [sp, #-16]!

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

Lgs_epilogue:
    mov x0, x2

    ldp x29, x30, [sp], #16
    ret


;; for HEAD, reply with just the header. pretty short n sweet.
head:
    bl get_setup ;; this does basically everything we want.

    ;; x0 is already set from get_setup
    mov x1, #-1
    mov x2, #-1
    bl build_header
    b.cs L500

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
;; input
;; x0 -> header received
;; x1 -> length of header
;;
;; returns
;; nothing ! :)
get:
    mov x20, x0
    mov x21, x1

    bl get_setup

    ;; if the file is 0 bytes long, let's skip the mmap and all that. just
    ;; close the file. x0 from get_setup
    cbz x0, Lget_end

    ;; let's save file length into x13! please? we need to use it but only in
    ;; this func -- i really don't wanna do more stack shit here...
    mov x13, x0

    mov x0, x20
    mov x1, x21
    bl parse_range
    b.cs Lno_range ; no range

    mov x22, x0
    mov x23, x1

    cmn x22, #1
    b.eq Lsuffix_range

    cmn x23, #1
    b.eq Lopen_range

    ;; if we're here, both are concrete.
    sub x1, x13, #1
    ;; if x23 > filesize - 1, set it to filesize - 1 so we don't read other
    ;; memory.
    cmp x23, x1
    csel x23, x1, x23, hi
    b Lbuild_ranged_header

Lsuffix_range:
    ;; if range is bigger than the file, just return the whole file.
    cmp x23, x13
    b.gt Lno_range

    ; Range: bytes=-50 means file_len - 50
    sub x22, x13, x23 ; start = len - range
    sub x23, x13, #1 ; end = fiolesize - 1 (inclusive)
    b Lbuild_ranged_header

Lopen_range:
    ;; if it's bytes=N-, start range remains unchanged, but end becomes
    ;; file_len - 1
    sub x23, x13, #1
    b Lbuild_ranged_header
    
Lno_range:
    ;; just pretend start = 0, end = file_length.
    mov x22, #0
    sub x23, x13, #1

    mov x0, x13
    mov x1, #-1
    mov x2, #-1
    bl build_header
    b.cs L500

    b Lmmap_start

Lbuild_ranged_header:
    ;; if start range >= filesize, that's unsatisfiable
    cmp x22, x13
    b.ge L416

    mov x0, x13
    mov x1, x22
    mov x2, x23
    bl build_header
    b.cs L500
    ;; fallthrough

Lmmap_start:
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
    ;; x22 -> start range
    ;; x23 -> end range
    ldr_l x0, clientfd
    add x1, x12, x22
    sub x2, x23, x22
    add x2, x2, #1
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
L400: b reply_400
L403: b reply_403
L416: b reply_416
L500: b reply_500
Lhfs_err: b handle_fs_error
