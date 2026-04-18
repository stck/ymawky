#include "defs.S"

.global get
.global delete
.align 4

;; my god there has got to be a better way to handle this
.data
head_response:
    .ascii "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: "
.equ head_response_len, . - head_response

head_content_type:
    .ascii "\r\nContent-Type: "
.equ head_content_type_len, . - head_content_type

good_response_tail:
    .ascii "\r\nAllow: GET, HEAD, OPTIONS, DELETE\r\nServer: ymawky\r\n\r\n"
.equ good_response_tail_len, . - good_response_tail

.bss
file_des:           .skip 8
filename_str:       .skip 8
filename_len:       .skip 8
file_contents:      .skip 8
file_length:        .skip 8
content_length_str: .skip 8
content_length_len: .skip 8


.text
do_path_checks:
    stp x29, x30, [sp, #-16]!

    adr_l x0, buf
    bl parse_path
    cbnz x0, 1f
    b reply_400
1:

    ;; x0 is already path, x1 is already path length
    bl decode_url
    cbnz x0, 1f
    b reply_400
1:

    str_l x0, filename_str
    str_l x1, filename_len

    bl check_path_safety
    cbnz x0, 1f
    b reply_400
1:

    bl check_path_traversal
    cbnz x0, 1f
    b reply_400
1:

    ldp x29, x30, [sp], #16
    ret

handle_stat_failed:
    cmp x0, #ENOENT
    b.eq 404f

    ;cmp x0, #ENOTDIR
    ;b.eq 404f

    cmp x0, #EACCES
    b.eq 403f

    cmp x0, #ENAMETOOLONG
    b.eq 414f

    cmp x0, #ELOOP
    b.eq 508f

    b reply_500

404:
    b reply_404
403:
    b reply_403
414:
    b reply_414
508:
    b reply_508

delete:
    bl do_path_checks
    ldr_l x0, filename_str

    bl stat_path
    cbnz x0, Ldelete_stat_failed
    cmp w1, #S_IFREG
    b.eq 1f
    b reply_403
1:

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
    cmp x0, #ENOENT
    b.ne 1f
    b reply_204
1:
    ;; if it's a dir, say it's not allowed. this could be 405, but i don't
    ;; want to build Allow: headers properly, lol. at least yet.
    cmp x0, #EISDIR
    b.eq 1f

    ;; other 403
    cmp x0, #EACCES
    b.eq 1f
    cmp x0, #EPERM
    b.eq 1f
    cmp x0, #EROFS
    b.eq 1f

    cmp x0, #EBUSY
    b.ne 2f
    b reply_409
2:
    b reply_500
1:
    b reply_403


get:
    bl do_path_checks
    ldr_l x0, filename_str

    bl stat_path
    cbnz x0, handle_stat_failed
    cmp w1, #S_IFREG
    b.eq 1f
    b reply_403
1:
    mov x21, x2 ; x2 should be file length from stat_path, store it in x21

    mov x16, SYS_open
    ldr_l x0, filename_str
    mov x1, #0 ; RDONLY
    svc #0x80
    b.cc 1f
    b reply_404 ; if the carry flag is set, read failed so 404
1:
    ;; save the file descriptor
    str_l x0, file_des

    ;; write(clientfd, response, response_len)
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_response
    mov x2, head_response_len
    svc #0x80

    ;; we gotta print the file length in the header as Content-Length
    ;; so lets convert it to a string!
    mov x0, x21
    bl itoa

    str_l x0, content_length_str ; pointer to start of string
    str_l x1, content_length_len ; length of string

    ;; write content-length
    mov x16, SYS_write
    ldr_l x0, clientfd
    ldr_l x1, content_length_str
    ldr_l x2, content_length_len
    svc #0x80

    ;; Write \r\nContent-Type: 
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_content_type
    mov x2, head_content_type_len
    svc #0x80

    ;; Get content type
    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl get_filetype

    ;; Now x0 is content-type string, x1 is the length of said string
    ;; write the content type to clientfd
    mov x16, SYS_write
    mov x2, x1 ;; length
    mov x1, x0 ;; string
    ldr_l x0, clientfd
    svc #0x80

    ;; Write the \r\n\r\n
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, good_response_tail
    mov x2, good_response_tail_len
    svc #0x80

    ;; x20 is the request type, currently GET or HEAD.
    ;; if it's a HEAD request, we just want to output the header, which we've
    ;; done, so jump to the end
    cmp x20, HEAD_REQ_ID
    b.eq 1f

    ;; if the file is 0 bytes long, let's skip the mmap and all that. just
    ;; close the file.
    cmp x21, #0
    b.le 9f

    ; mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0)
    mov x16, SYS_mmap
    mov x0, #0
    mov x1, x21
    mov x2, #1 ; PROT_READ
    mov x3, #2 ; MAP_PRIVATE
    ldr_l x4, file_des ; file descriptor
    mov x5, #0 ; offset
    svc #0x80
    b.cs 9f
    ;; x0 is now the pointer to memory for the file

    ;; stash the pointer somewhere safe
    mov x12, x0

    ;; x12 -> pointer to mmap'd memory
    ;; x21 -> total length of file
    mov x10, x12  ; current position
    mov x11, x21 ; remaining bytes
_write_loop:
    ;; if we have 0 (or fewer) bytes remaining, skip to the end of the write
    ;; loop.
    cbz x11, _write_done

    ;; write(clientfd, mmap_ptr, size)
    mov x16, SYS_write
    ldr_l x0, clientfd
    mov x1, x10
    mov x2, x11
    svc #0x80
    b.cs 9f ;; uh oh something went wrong, we gotta mmunmap the file
            ;; and stuff now.

    ; x0 -> bytes written
    add x10, x10, x0 ; advance the pointer by x0 bytes
    sub x11, x11, x0 ; and decrease remaining bytes by x0 bytes
    b _write_loop

_write_done:
    mov x16, SYS_munmap
    mov x0, x12
    mov x1, x21
    svc #0x80
    b.cs 9f

;; close the file
9:
    mov x16, SYS_close
    ldr_l x0, file_des
    svc #0x80

1:
    b child_end
