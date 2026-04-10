#include "defs.S"

.global _main
.global loop_end
.align 4

.data
one: .word 1
addr:
    .byte 0x02, 0x00             ; AF_INET (2) + padding byte
    .byte 0x1f, 0x90             ; Port 8080, big-endian
    .byte 0x7F, 0x00, 0x00, 0x01 ; 127.0.0.1
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; padding

get_req:
    .ascii "GET "
.equ get_req_len, . - get_req

head_req:
    .ascii "HEAD "
.equ head_req_len, . - head_req

.bss
sockfd:             .skip 8


.text
_main:
    ;; socket(AF_INET, SOCK_STREAM, 0)
    mov x16, SYS_socket
    mov x0, #2 ; AF_INET
    mov x1, #1 ; SOCK_STREAM
    mov x2, #0 ; nothin, TCP
    svc #0x80

    str_l x0, sockfd

    ;; setsockopt(serverfd, SOL_SOCKET, SO_REUSEADDR, &value, 4)
    mov x16, SYS_setsockopt
    ldr_l x0, sockfd
    mov x1, #0xFFFF ; SOL_SOCKET = 0xFFFF
    mov x2, #4 ; SO_REUSEADDR = 4
    adr_l x3, one
    mov x4, #4 ; sizeof int
    svc #0x80

    ;; bind(sockfd, &addr, 16)
    mov x16, SYS_bind
    ldr_l x0, sockfd
    adr_l x1, addr
    mov x2, #16 ; the struct is 16 bytes
    svc #0x80

    ;; listen(sockfd, 5)
    mov x16, SYS_listen
    ldr_l x0, sockfd
    mov x1, #5
    svc #0x80

loop:
    ;; accept(sockfd, NULL, NULL)
    mov x16, SYS_accept
    ldr_l x0, sockfd
    mov x1, #0
    mov x2, #0
    svc #0x80

    ;; store x0 (return of accept) in clientfd
    str_l x0, clientfd

    ;; read(client_fd, buffer, buffer_size)
    mov x16, SYS_read
    ldr_l x0, clientfd
    adr_l x1, buf
    mov x2, BUF_SIZE
    svc #0x80

    ;; If nothing is read, quit!
    cbz x0, exit

    ;; let's make sure buf is NULL terminated
    adr_l x1, buf
    strb wzr, [x1, x0] ; x0 -> length of bytes read

    ;; this just writes the request to stdout
    mov x2, x0
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, buf
    svc #0x80

    ;; check if we got a GET request. if so, jump to get!
    adr_l x0, buf
    adr_l x1, get_req
    mov x2, get_req_len
    bl strcmp

    cmp x0, #1
    b.eq 1f

    ;; check if maybe we got a HEAD request instead.
    adr_l x0, buf
    adr_l x1, head_req
    mov x2, head_req_len
    bl strcmp

    cmp x0, #1
    b.eq 2f

    ;; if it was neither, reply 501
    b reply_501

1:
    mov x20, GET_REQ_ID
    b get

2:
    mov x20, HEAD_REQ_ID
    b get

loop_end:
    ;; close(clientfd)
    mov x16, SYS_close
    ldr_l x0, clientfd
    svc #0x80

    b loop

exit:
    ;; shutdown(sockfd, SHUT_RDRW)
    mov x16, SYS_shutdown
    ldr_l x0, sockfd
    mov x1, #2 ; SHUT_RDRW
    svc #0x80

    ;; close(sockfd)
    mov x16, SYS_close
    ldr_l x0, sockfd
    svc #0x80

    ;; exit(1)
    mov x16, SYS_exit
    mov x0, #1
    svc #0x80
