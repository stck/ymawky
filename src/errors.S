;; errors.S
;; HTTP error/status response handlers, plus errno -> HTTP code routing
;; (handle_fs_error).

#include "defs.S"

.global reply_201
.global reply_204
.global reply_400
.global reply_403
.global reply_404
.global reply_408
.global reply_409
.global reply_416
.global reply_411
.global reply_413
.global reply_414
.global reply_418
.global reply_431
.global reply_500
.global reply_501
.global reply_507
.global handle_fs_error

.data
header_201: .ascii "HTTP/1.1 201 Created"
.equ header_201_len, . - header_201

header_204: .ascii "HTTP/1.1 204 No Content\r\nConnection: close\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n\r\n"
.equ header_204_len, . - header_204

header_400: .ascii "HTTP/1.1 400 Bad Request"
.equ header_400_len, . - header_400

header_403: .ascii "HTTP/1.1 403 Forbidden"
.equ header_403_len, . - header_403

header_404: .ascii "HTTP/1.1 404 Not Found"
.equ header_404_len, . - header_404

header_408: .ascii "HTTP/1.1 408 Request Timeout"
.equ header_408_len, . - header_408

header_409: .ascii "HTTP/1.1 409 Conflict"
.equ header_409_len, . - header_409

header_411: .ascii "HTTP/1.1 411 Length Required"
.equ header_411_len, . - header_411

header_413: .ascii "HTTP/1.1 413 Content Too Large"
.equ header_413_len, . - header_413

header_414: .ascii "HTTP/1.1 414 URI Too Long"
.equ header_414_len, . - header_414

header_416: .ascii "HTTP/1.1 416 Range Not Satisfiable"
.equ header_416_len, . - header_416

header_418: .ascii "HTTP/1.1 418 I'm a teapot"
.equ header_418_len, . - header_418

header_431: .ascii "HTTP/1.1 431 Request Header Fields Too Large"
.equ header_431_len, . - header_431

header_500: .ascii "HTTP/1.1 500 Internal Server Error"
.equ header_500_len, . - header_500

header_501: .ascii "HTTP/1.1 501 Not Implemented"
.equ header_501_len, . - header_501

header_507: .ascii "HTTP/1.1 507 Insufficient Storage"
.equ header_507_len, . - header_507

header_tail:
    .ascii "\r\nConnection: close\r\nContent-Length: 0\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n\r\n"
.equ header_tail_len, . - header_tail


.text
.align 2

reply_201:
    adr_l x3, header_201
    mov x4, header_201_len
    b send_reply

reply_204:
    ; write to stdout for logging and stuff
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, header_204
    mov x2, header_204_len
    svc #0x80

    ; write to socket
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, header_204
    mov x2, header_204_len
    svc #0x80

    b child_end

reply_400:
    adr_l x3, header_400
    mov x4, header_400_len
    b send_reply

reply_403:
    adr_l x3, header_403
    mov x4, header_403_len
    b send_reply

reply_404:
    adr_l x3, header_404
    mov x4, header_404_len
    b send_reply

reply_408:
    adr_l x3, header_408
    mov x4, header_408_len
    b send_reply

reply_409:
    adr_l x3, header_409
    mov x4, header_409_len
    b send_reply

reply_411:
    adr_l x3, header_411
    mov x4, header_411_len
    b send_reply

reply_413:
    adr_l x3, header_413
    mov x4, header_413_len
    b send_reply

reply_414:
    adr_l x3, header_414
    mov x4, header_414_len
    b send_reply

reply_416:
    adr_l x3, header_416
    mov x4, header_416_len
    b send_reply

reply_418:
    adr_l x3, header_418
    mov x4, header_418_len
    b send_reply

reply_431:
    adr_l x3, header_431
    mov x4, header_431_len
    b send_reply

reply_500:
    adr_l x3, header_500
    mov x4, header_500_len
    b send_reply

reply_501:
    adr_l x3, header_501
    mov x4, header_501_len
    b send_reply

reply_507:
    adr_l x3, header_507
    mov x4, header_507_len
    b send_reply


;; input
;; x3 -> header string
;; x4 -> header length
;;
;; no output.
;; clobbers x0-x3
send_reply:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    mov x19, x3
    mov x20, x4

    ; write to stdout for logging
    mov x16, SYS_write
    mov x0, #1
    mov x1, x3
    mov x2, x4
    svc #0x80

    mov x16, SYS_write
    mov x0, #1
    adr_l x1, header_tail
    mov x2, header_tail_len
    svc #0x80

    ;; now write to the socket with write_all.
    ldr_l x0, clientfd
    mov x1, x19
    mov x2, x20
    bl write_all

    ;; the end of the header
    ldr_l x0, clientfd
    adr_l x1, header_tail
    mov x2, header_tail_len
    bl write_all

    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32

    b child_end


;; handler function for fstat64() failing. route to the proper HTTP reponse
;; based on errno.
;; input
;; x0 -> errno
;;
;; output
;; none, branches to reply_* and quits.
handle_fs_error:
    cb eq, x0, #ENAMETOOLONG, reply_414
    cb eq, x0, #EINVAL, reply_400
    ;; 403 since it's caused by O_NOFOLLOW_ANY most likely. if we ever allow
    ;; symlinks, note that this should be 508.
    cb eq, x0, #ELOOP, reply_403
    cb eq, x0, #ENOTDIR, reply_404
    cb eq, x0, #ENOENT, reply_404
    cb eq, x0, #EACCES, reply_403
    cb eq, x0, #EPERM, reply_403
    cb eq, x0, #EROFS, reply_403
    cb eq, x0, #EISDIR, reply_403
    cb eq, x0, #EFAULT, reply_500
    cb eq, x0, #EBUSY, reply_409
    cb eq, x0, #ENOTEMPTY, reply_409
    cb eq, x0, #ENOSPC, reply_507
    cb eq, x0, #EDQUOT, reply_507
    cb eq, x0, #EFBIG, reply_413

    b reply_500
