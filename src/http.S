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
    cbz x0, L400

    ;; x0 is already path, x1 is already path length
    bl decode_url
    cbz x0, L400

    str_l x0, filename_str
    str_l x1, filename_len

    bl check_path_safety
    cbz x0, L400

    bl check_path_traversal
    cbz x0, L400

    ldp x29, x30, [sp], #16
    ret

handle_stat_failed:
    cb eq, x0, #ENOENT, L404
    cb eq, x0, #EACCES, L403
    cb eq, x0, #ENAMETOOLONG, L414
    cb eq, x0, #ELOOP, L508
    ;cb eq, x0, #ENOTDIR, L404

    b reply_500

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
    cb eq, x0, ENOENT, L204

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

get:
    bl do_path_checks
    ldr_l x0, filename_str

    bl stat_path
    cbnz x0, handle_stat_failed
    cmp w1, #S_IFREG
    b.ne L403

    mov x21, x2 ; x2 should be file length from stat_path, store it in x21

    mov x16, SYS_open
    ldr_l x0, filename_str
    mov x1, #0 ; RDONLY
    svc #0x80
    b.cs L404 ; if the carry flag is set, open() failed so 404

    ;; save the file descriptor
    str_l x0, file_des

    ;; TODO
    ;; write the header into a buffer, then mmap file, then write header to
    ;; the socket, check if HEAD method, if not, write file contents to socket
    ;; then close/munmap file. this would prevent a mangled half-header from
    ;; being sent if one of these writes fails.

    ;; write(clientfd, response, response_len)
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_response
    mov x2, head_response_len
    svc #0x80
    b.cs Lget_end

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
    b.cs Lget_end

    ;; Write \r\nContent-Type: 
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_content_type
    mov x2, head_content_type_len
    svc #0x80
    b.cs Lget_end

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
    b.cs Lget_end

    ;; Write the \r\n\r\n
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, good_response_tail
    mov x2, good_response_tail_len
    svc #0x80
    b.cs Lget_end

    ;; x20 is the request type, currently GET or HEAD.
    ;; if it's a HEAD request, we just want to output the header, which we've
    ;; done, so jump to the end
    cmp x20, HEAD_REQ_ID
    b.eq Lget_end

    ;; if the file is 0 bytes long, let's skip the mmap and all that. just
    ;; close the file.
    cmp x21, #0
    b.le Lget_end

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

L204: b reply_204
L400: b reply_400
L403: b reply_403
L404: b reply_404
L409: b reply_409
L414: b reply_414
L500: b reply_500
L508: b reply_508
