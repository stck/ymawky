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
file_des:             .skip 8
filename_str:         .skip 8
filename_len:         .skip 8
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

;; handler function for stat64() failing. route to the proper HTTP reponse
;; based on errno.
;; input
;; x0 -> errno
;;
;; output
;; none, branches to reply_* and quits.
handle_stat_failed:
    cb eq, x0, #ENOENT, L404
    cb eq, x0, #EACCES, L403
    cb eq, x0, #ENAMETOOLONG, L414
    cb eq, x0, #ELOOP, L508

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

;; handle "PUT /" method.
;; input
;; x0 -> header
;; x1 -> length of header
;;
;; output
;; none, proc quits after handling.
put:
    bl do_path_checks
    ldr_l x0, filename_str

    bl parse_content_length

    brk #1
    ;;TODO XXX XXX TODO TODO XXX XXX TODO TODO XXX XXX TODO TODO XXX XXX TODO;
    ;; 1. open filename_str                                                 ;;
    ;; 2. check for errors opening                                          ;;
    ;; 3. use header length and some total_header_bytes register to         ;;
    ;;    determine the offset in case the header chunk contains some of the;;
    ;;    data to be PUT.                                                   ;;
    ;; 4. write whatever is remaining from the buffer to the file.          ;;
    ;; 5. read/write loop until EOF. read from socket writing to file.      ;;
    ;; 6. close it i guess                                                  ;;
    ;; 7. reply with a header for:                                          ;;
    ;;    201 File Created for new file,                                    ;;
    ;;    204 New Content for overwritten file,                             ;;
    ;; Content-Length: 0 since PUT response body is empty.                  ;;
    ;; Optionally Location: /path on 201. Unneeded.                         ;;
    ;; Errors to consider:                                                  ;;
    ;; 1. 400 Bad Request -- Malformed Request (bad Content-Length, missing ;;
    ;;    headers)                                                          ;;
    ;; 2. 403 Forbidden -- Path traversal attempt or permissions violations ;;
    ;; 3. 411 Length Required -- no Content-Length header                   ;;
    ;; 4. 413 Payload Too Large -- body exceeds some maximum filesize.      ;;
    ;; 5. 500 Internal Server Error -- disk full, write() failed, other     ;;
    ;;    system errors.                                                    ;;
    ;;TODO XXX XXX TODO TODO XXX XXX TODO TODO XXX XXX TODO TODO XXX XXX TODO;

;; handle "GET /" method.
;; input
;; none, uses .bss data
;;
;; output
;; none, proc quits after handling.
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

;; i can't cmp xN, xN; b.eq reply_*, since reply_* are in other files. it's
;; too far for conditional branching. so, i've gotta have these private labels
;; so i can conditionally branch.
L204: b reply_204
L400: b reply_400
L403: b reply_403
L404: b reply_404
L409: b reply_409
L414: b reply_414
L500: b reply_500
L508: b reply_508
