#include "defs.S"

.global get
.global reply_204
.global reply_400
.global reply_404
.global reply_501
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
    .ascii "\r\nAllow: GET, HEAD, OPTIONS\r\nServer: ymawky\r\n\r\n"
.equ good_response_tail_len, . - good_response_tail

header_400:
    .ascii "HTTP/1.1 400 Bad Request"
.equ header_400_len, . - header_400

header_500:
    .ascii "HTTP/1.1 500 Internal Server Error"
.equ header_500_len, . - header_500

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
file_des:           .skip 8
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

    ;; x0 is already path, x1 is already path length
    bl decode_url
    cmp x0, #0
    b.eq reply_400

    ;; store the decoded filename from parse_path into filename_str
    ;; and the length into x1
    str_l x0, filename_str
    str_l x1, filename_len

    ;; check for legal/illegal data in the path
    bl check_path_safety
    cbz x0, reply_400

    ;; if the path contains .., it's probably unsafe. so reject it.
    bl check_path_traversal
    cbz x0, reply_400

    ldr_l x0, filename_str

    mov x16, SYS_open
    ; x0 should already be set
    mov x1, #0 ; RDONLY
    svc #0x80
    b.cs reply_404 ; if the carry flag is set, read failed so 404

    ;; save the file descriptor
    str_l x0, file_des

    mov x16, SYS_lseek
    ; x0 should now be the file descriptor
    mov x1, #0 ; offset
    mov x2, #2 ; SEEK_END
    svc #0x80
    b.cs 9f

    ;; now x0 should be file length, let's store it in x21
    mov x21, x0

    ;; let's rewind the file back to the beginning
    mov x16, SYS_lseek
    ldr_l x0, file_des
    mov x1, #0 ; offset
    mov x2, #0 ; SEEK_SET, beginning
    svc #0x80
    b.cs 9f

    ;; write(clientfd, response, response_len)
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, head_response
    mov x2, head_response_len
    svc #0x80

    ;; we gotta print the file length in the header as Content-Length
    ;; so lets convert it to a string!
    ;ldr_l x0, file_length
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
    b loop_end

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

    b loop_end

reply_500:
    adr_l x3, header_500
    mov x4, header_500_len
    b send_reply

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

    b loop_end
