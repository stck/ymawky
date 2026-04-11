#include "defs.S"

.global get
.global reply_204
.global reply_400
.global reply_404
.global reply_501
.align 4

.data
head_response:
    .ascii "HTTP/1.1 200 OK\r\nContent-Length: "
.equ head_response_len, . - head_response

head_content_type:
    .ascii "\r\nContent-Type: "
.equ head_content_type_len, . - head_content_type

line_breaks:
    .ascii "\r\nAllow: GET, HEAD\r\nServer: ymawky\r\n\r\n"
.equ line_breaks_len, . - line_breaks

header_400:
    .ascii "HTTP/1.1 400 Bad Request"
.equ header_400_len, . - header_400

header_501:
    .ascii "HTTP/1.1 501 Not Implemented"
.equ header_501_len, . - header_501

header_404:
    .ascii "HTTP/1.1 404 Not Found"
.equ header_404_len, . - header_404

header_204:
    .ascii "HTTP/1.1 204 No Content\r\nAllow: GET, HEAD, OPTIONS\r\nServer: ymawky\r\n\r\n"
.equ header_204_len, . - header_204

header_tail:
    .ascii "\r\nConnection: close\r\nContent-Length: 0\r\nAllow: GET, HEAD, OPTIONS\r\nServer: ymawky\r\n\r\n"
.equ header_tail_len, . - header_tail

.bss
filename_str:       .skip 8
filename_len:       .skip 8
file_contents:      .skip 8
file_length:        .skip 8
content_length_str: .skip 8
content_length_len: .skip 8


.text
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

    ;; if the path contains .., it's probably unsafe. so reject it.
    bl check_path_safety
    cbz x0, reply_400

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
    b.eq 1f

    ;; Write the contents of the requested file
    mov x16, SYS_write
    ldr_l x0, clientfd
    ldr_l x1, file_contents
    ldr_l x2, file_length
    svc #0x80

1:
    b loop_end

reply_204:
    ; write to stdout
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

    b loop_end

reply_501:
    adr_l x3, header_501
    mov x4, header_501_len
    b send_reply

reply_400:
    adr_l x3, header_400
    mov x4, header_400_len
    b send_reply

reply_404:
    adr_l x3, header_404
    mov x4, header_404_len
    b send_reply

send_reply:
    ; write to stdout
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

    ; write to stdout
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

    b loop_end
