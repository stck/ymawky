.global _main
.align 4

.equ SYS_setsockopt, 105
.equ SYS_socket, 97
.equ SYS_shutdown, 134
.equ SYS_close, 6
.equ SYS_bind, 104
.equ SYS_listen, 106
.equ SYS_accept, 30
.equ SYS_read, 3
.equ SYS_write, 4
.equ SYS_close, 6
.equ SYS_exit, 1
.equ BUF_SIZE, 16384

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

line_breaks:
    .ascii "\r\n\r\n"
.equ line_breaks_len, . - line_breaks

head_404:
    .ascii "HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
.equ head_404_len, . - head_404

.bss
buf: .skip BUF_SIZE

.text
_main:
    ;; socket(AF_INET, SOCK_STREAM, 0)
    mov x16, SYS_socket
    mov x0, #2 ; AF_INET
    mov x1, #1 ; SOCK_STREAM
    mov x2, #0 ; nothin, TCP
    svc #0x80

    mov x20, x0 ; back up the sockfd in x20

    ;; setsockopt(serverfd, SOL_SOCKET, SO_REUSEADDR, &value, 4)
    mov x16, SYS_setsockopt
    mov x0, x20
    mov x1, #0xFFFF ; SOL_SOCKET = 0xFFFF
    mov x2, #4 ; SO_REUSEADDR = 4
    adrp x3, one@PAGE
    add x3, x3, one@PAGEOFF
    mov x4, #4 ; sizeof int
    svc #0x80

    ;; bind(sockfd, &addr, 16)
    mov x16, SYS_bind
    mov x0, x20
    adrp x1, addr@PAGE ; load the address struct
    add x1, x1, addr@PAGEOFF
    mov x2, #16 ; the struct is 16 bytes
    svc #0x80

    ;; listen(sockfd, 5)
    mov x16, SYS_listen
    mov x0, x20
    mov x1, #5
    svc #0x80

loop:
    ;; accept(sockfd, NULL, NULL)
    mov x16, SYS_accept
    mov x0, x20
    mov x1, #0
    mov x2, #0
    svc #0x80

    ;; clientfd = x0
    mov x21, x0

    ;; read(client_fd, buffer, buffer_size)
    mov x16, SYS_read
    mov x0, x21
    adrp x1, buf@PAGE
    add x1, x1, buf@PAGEOFF
    mov x2, BUF_SIZE
    svc #0x80
    ;mov x0, x27 ; save the length of this

    ;; this just writes the request to stdout
    mov x2, x0
    mov x16, SYS_write
    mov x0, #1
    adrp x1, buf@PAGE
    add x1, x1, buf@PAGEOFF
    svc #0x80

    ;; TODO:
    ;; parse the first line of buf, which is the request
    ;; search for GET /*, find the filename being requested
    ;; then store that filename as a string, and serve that file

    ;; If nothing is read, quit!
    cbz x0, exit

    ;; TODO:
    ;; x1 should already point to buf from the read call above. can i just
    ;; mov x0, x1? or does read() clobber x1?
    adrp x0, buf@PAGE
    add x0, x0, buf@PAGEOFF
    bl parse_path
    mov x26, x0 ; store filename in x26
    ;mov x27, x1 ; store filename length in x27

bpoint:
    ;; we gotta try to read the file before sending the header. if read_file
    ;; fails, we gotta 404
    mov x0, x26
    bl read_file
    ;; if the read_file failed, file doesn't exist. so we reply 404.
    ;; reply_404 jumps back to the end of the loop, where we close the
    ;; connection and open a new one
    b.cs reply_404
    ;;cmp x0, #0
    ;;b.lt reply_404
    mov x22, x0 ; pointer to file content string
    mov x23, x1 ; bytes read from file, aka file size (must be <65536 rn)

    ;; write(clientfd, response, response_len) to stdout
    ;mov x16, SYS_write
    ;mov x0, #1
    ;adrp x1, head_response@PAGE
    ;add x1, x1, head_response@PAGEOFF
    ;mov x2, head_response_len
    ;svc #0x80
    ;; write(clientfd, response, response_len)
    mov x16, SYS_write
    mov x0, x21
    adrp x1, head_response@PAGE
    add x1, x1, head_response@PAGEOFF
    mov x2, head_response_len
    svc #0x80

    mov x0, x23 ; load x0 with bytes read for itoa
    bl itoa
    mov x24, x0 ; pointer to start of string
    mov x25, x1 ; length of string

    ;; write content-length to stdout
    ;mov x16, SYS_write
    ;mov x0, #1
    ;mov x1, x24
    ;mov x2, x25
    ;svc #0x80
    ;; write content-length
    mov x16, SYS_write
    mov x0, x21
    mov x1, x24
    mov x2, x25
    svc #0x80

    ;; Write the \r\n\r\n to stdout
    ;mov x16, SYS_write
    ;mov x0, #1
    ;adrp x1, line_breaks@PAGE
    ;add x1, x1, line_breaks@PAGEOFF
    ;mov x2, line_breaks_len
    ;svc #0x80
    ;; Write the \r\n\r\n
    mov x16, SYS_write
    mov x0, x21
    adrp x1, line_breaks@PAGE
    add x1, x1, line_breaks@PAGEOFF
    mov x2, line_breaks_len
    svc #0x80

    ;; Write the contents of index.html to stdout
    ;mov x16, SYS_write
    ;mov x0, #1
    ;mov x1, x22
    ;mov x2, x23
    ;svc #0x80
    ;; Write the contents of index.html
    mov x16, SYS_write
    mov x0, x21
    mov x1, x22
    mov x2, x23
    svc #0x80

loop_end:
    ;; close(clientfd)
    mov x16, SYS_close
    mov x0, x21
    svc #0x80

    b loop

reply_404:
    ; write to stdout
    mov x16, SYS_write
    mov x0, #1
    adrp x1, head_404@PAGE
    add x1, x1, head_404@PAGEOFF
    mov x2, head_404_len
    svc #0x80
    ; write to socket
    mov x16, SYS_write
    mov x0, x21
    adrp x1, head_404@PAGE
    add x1, x1, head_404@PAGEOFF
    mov x2, head_404_len
    svc #0x80

    b loop_end

exit:
    ;; shutdown(sockfd, SHUT_RDRW)
    mov x16, SYS_shutdown
    mov x0, x20
    mov x1, #2 ; SHUT_RDRW
    svc #0x80

    ;; close(sockfd)
    mov x16, SYS_close
    mov x0, x20
    svc #0x80

    ;; exit(1)
    mov x16, SYS_exit
    mov x0, #1
    svc #0x80
