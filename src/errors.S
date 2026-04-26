#include "defs.S"

.global reply_201
.global reply_204
.global reply_400
.global reply_403
.global reply_404
.global reply_408
.global reply_409
.global reply_411
.global reply_413
.global reply_414
.global reply_418
.global reply_431
.global reply_500
.global reply_501
.global reply_507
.global reply_508

.data
header_201: .ascii "HTTP/1.1 201 Created"
.equ header_201_len, . - header_201

header_204: .ascii "HTTP/1.1 204 No Content\r\nConnection: close\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nServer: ymawky\r\n\r\n"
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

header_508: .ascii "HTTP/1.1 508 Loop Detected"
.equ header_508_len, . - header_508

header_tail:
    .ascii "\r\nConnection: close\r\nContent-Length: 0\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nServer: ymawky\r\n\r\n"
.equ header_tail_len, . - header_tail


.text
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

reply_508:
    adr_l x3, header_508
    mov x4, header_508_len
    b send_reply

;; input
;; x3 -> header string
;; x4 -> header length
;;
;; no output.
;; clobbers x0-x3
send_reply:
    ; write to stdout for logging
    mov x16, SYS_write
    mov x0, #1
    mov x1, x3
    mov x2, x4
    svc #0x80

    ; write to stdout
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, header_tail
    mov x2, header_tail_len
    svc #0x80

    ; write to socket
    mov x16, SYS_write
    ldr_l x0, clientfd
    mov x1, x3
    mov x2, x4
    svc #0x80

    ; write to socket
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, header_tail
    mov x2, header_tail_len
    svc #0x80

    b child_end
