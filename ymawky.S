#include "defs.S"

.global _main
.align 4

.data
one: .word 1
addr:
    .byte 0x02, 0x00             ; AF_INET (2) + padding byte
    .byte 0x1f, 0x90             ; Port 8080, big-endian
    .byte 0x7F, 0x00, 0x00, 0x01 ; 127.0.0.1
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; padding

head_response:
    .ascii "HTTP/1.1 200 OK\r\nContent-Length: "
.equ head_response_len, . - head_response

head_content_type:
    .ascii "\r\nContent-Type: "
.equ head_content_type_len, . - head_content_type

line_breaks:
    .ascii "Allow: GET, HEAD\r\nServer: ymawky\r\n\r\n"
.equ line_breaks_len, . - line_breaks

get_req:
    .ascii "GET "
.equ get_req_len, . - get_req

head_req:
    .ascii "HEAD "
.equ head_req_len, . - head_req

head_400:
    .ascii "HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\nAllow: GET, HEAD\r\nServer: ymawky\r\n\r\n"
.equ head_400_len, . - head_400

head_501:
    .ascii "HTTP/1.1 501 Not Implemented\r\nConnection: close\r\nContent-Length: 0\r\nAllow: GET, HEAD\r\nServer: ymawky\r\n\r\n"
.equ head_501_len, . - head_501

head_404:
    .ascii "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\nAllow: GET, HEAD\r\nServer: ymawky\r\n\r\n"
.equ head_404_len, . - head_404

.bss
;; + 1 so we can NULL terminate, even if content is BUF_SIZE bytes long
buf:                .skip BUF_SIZE + 1
sockfd:             .skip 8
clientfd:           .skip 8
read_bytes:         .skip 8
filename_str:       .skip 8
filename_len:       .skip 8
file_contents:      .skip 8
file_length:        .skip 8
content_length_str: .skip 8
content_length_len: .skip 8


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

get:
    ;; parse GET /..., extract the filename we're GETting.
    adr_l x0, buf
    bl parse_path

    cmp x0, #0 ; did parse_path return null? if so we gotta send a 400
    b.eq reply_400

    ;; store the filename from parse_path into filename_str
    ;; and the length into x1
    str_l x0, filename_str
    str_l x1, filename_len

    ;; we gotta try to read the file before sending the header. if read_file
    ;; fails, we gotta 404
    ldr_l x0, filename_str
    bl read_file
    ;; if the read_file failed, file doesn't exist. so we reply 404.
    ;; reply_404 jumps back to the end of the loop, where we close the
    ;; connection and open a new one
    b.cs reply_404

    str_l x0, file_contents ; pointer to file contents as a string
    str_l x1, file_length   ; bytes read from file, size (under 65536)

    ;; write(clientfd, response, response_len)
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_response
    mov x2, head_response_len
    svc #0x80

    ;; we gotta print the file length in the header as Content-Length
    ;; so lets convert it to a string!
    ldr_l x0, file_length
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

    ;;; XXX
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
    adr_l x1, line_breaks
    mov x2, line_breaks_len
    svc #0x80

    ;; x20 is the request type, currently GET or HEAD.
    ;; if it's a HEAD request, we just want to output the header, which we've
    ;; done, so jump to the end
    cmp x20, HEAD_REQ_ID
    b.eq loop_end

    ;; Write the contents of the requested file
    mov x16, SYS_write
    ldr_l x0, clientfd
    ldr_l x1, file_contents
    ldr_l x2, file_length
    svc #0x80

loop_end:
    ;; close(clientfd)
    mov x16, SYS_close
    ldr_l x0, clientfd
    svc #0x80

    b loop

reply_501:
    ; write to stdout
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, head_501
    mov x2, head_501_len
    svc #0x80

    ; write to socket
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_501
    mov x2, head_501_len
    svc #0x80

    b loop_end

reply_400:
    ; write to stdout
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, head_400
    mov x2, head_400_len
    svc #0x80

    ; write to socket
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_400
    mov x2, head_400_len
    svc #0x80

    b loop_end

reply_404:
    ; write to stdout
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, head_404
    mov x2, head_404_len
    svc #0x80

    ; write to socket
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_404
    mov x2, head_404_len
    svc #0x80

    b loop_end

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
