#include "defs.S"

.global _main
.global child_end
.align 4

.data
.align 3
rcv_timeout:
    .quad 10  ; tv_sec, 10 second timeout. change for longer.
    .quad 0   ; tv_usec

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

options_req:
    .ascii "OPTIONS "
.equ options_req_len, . - options_req

delete_req:
    .ascii "DELETE "
.equ delete_req_len, . - delete_req

.bss
sockfd:             .skip 8

.text
_main:
    ;; did we get an argument
    cmp x0, #1
    b.le skip_argv

    ;; get argv0.
    ldr x0, [x1, #8]
    bl atoi
    b.cs fatal_exit

    ;; now x0 contains the integer representation of argv[1]
    mov x2, #65535
    cmp x0, x2
    b.gt fatal_exit

    ;; overwrite the address struct's port with the custom port.
    rev16 w0, w0 ; make x0 big-endian, which the port needs to be
    adr_l x1, addr
    strh w0, [x1, #2]

skip_argv:
    ;; socket(AF_INET, SOCK_STREAM, 0)
    mov x16, SYS_socket
    mov x0, #2 ; AF_INET
    mov x1, #1 ; SOCK_STREAM
    mov x2, #0 ; nothin, TCP
    svc #0x80
    b.cs fatal_exit

    str_l x0, sockfd

    ;; setsockopt(serverfd, SOL_SOCKET, SO_REUSEADDR, &value, 4)
    mov x16, SYS_setsockopt
    ldr_l x0, sockfd
    mov x1, #0xFFFF ; SOL_SOCKET = 0xFFFF
    mov x2, #4 ; SO_REUSEADDR = 4
    adr_l x3, one
    mov x4, #4 ; sizeof int
    svc #0x80
    b.cs exit

    ;; bind(sockfd, &addr, 16)
    mov x16, SYS_bind
    ldr_l x0, sockfd
    adr_l x1, addr
    mov x2, #16 ; the struct is 16 bytes
    svc #0x80
    b.cs exit

    ;; listen(sockfd, 5)
    mov x16, SYS_listen
    ldr_l x0, sockfd
    mov x1, #5
    svc #0x80
    b.cs exit
;; NOTE NOTE NOTE
;; uncomment this line to debug with lldb.
  b 1f
;; NOTE NOTE NOTE
loop:
;; reap any dead child processes
Lreap:
    mov x16, SYS_wait4
    mov x0, #-1 ; any child
    mov x1, #0  ; status = NULL
    mov x2, #1  ; WNOHANG
    mov x3, #0  ; rusage = NULL
    svc #0x80
    b.cs 1f
    cmp x0, #0  ; if we reaped some children, there might be more
    b.le 1f

    b Lreap
1:

    ;; accept(sockfd, NULL, NULL)
    mov x16, SYS_accept
    ldr_l x0, sockfd
    mov x1, #0
    mov x2, #0
    svc #0x80
    b.cs loop ;; loop if accept() failed.

    ;; store x0 (return of accept) in clientfd
    str_l x0, clientfd

    ;; TODO set a sock opt for read timeout? after accept? SO_RCVTIMEO?

;; NOTE NOTE NOTE
;; uncomment this line to debug with lldb.
  b child
;; NOTE NOTE NOTE
    ;; fork()
    mov x16, SYS_fork
    svc #0x80
    ;; if it fails, we just want to close clientfd and loop anyway, so there's
    ;; no particular error handling/b.cs here.

    ;; if we're in the child, go there
    ;; NOTE
    ;; on macos, fork() returns the pid of the child process in x0 in the
    ;; parent process. in the child process, it puts 1 in x1. on linux, fork
    ;; will put 0 in x0 in the child, or the pid in x0 in the parent. so it's
    ;; a bit different. if you're on linux, you've got to change this to
    ;; cmp x0, #0
    cmp x1, #1
    b.eq child

    ;; otherwise close clientfd and loop
    mov x16, SYS_close
    ldr_l x0, clientfd
    svc #0x80

    b loop

child:
    ;; close sockfd
    mov x16, SYS_close
    ldr_l x0, sockfd
    svc #0x80

    ;; setsockopt() with a 10 second SO_RCVTIMEO timeout, to prevent
    ;; connections from staying open indefinitely
    mov x16, SYS_setsockopt
    ldr_l x0, clientfd
    mov x1, #0xFFFF ; SOL_SOCKET
    mov x2, #0x1006 ; SO_RCVTIMEO = 0x1006
    adr_l x3, rcv_timeout ; 10 seconds, 0 usec
    mov x4, #16 ; struct timeval is 16 bytes
    svc #0x80
    b.cs child_end

    ;; setsockopt(), SO_NOSIGPIPE
    mov x16, SYS_setsockopt
    ldr_l x0, clientfd
    mov x1, 0xFFFF ; SOL_SOCKET
    mov x2, 0x1022 ; SO_NOSIGPIPE
    adr_l x3, one
    mov x4, #4
    svc #0x80
    b.cs child_end

    ;; read(client_fd, buffer, buffer_size)
    mov x7, #0
read_loop:
    mov x16, SYS_read
    ldr_l x0, clientfd
    adr_l x1, buf
    add x1, x1, x7 ; account for buffer being partially filled
    mov x6, #BUF_SIZE
    sub x2, x6, x7 ; BUF_SIZE - bytes_read (six seveeen)
    svc #0x80
    b.cs read_failed
    mov x6, x0 ; stash number of bytes read() got in x6

    add x7, x7, x0 ; save x0 because parse_header_end clobbers it. cumulatively

    adr_l x0, buf
    mov x1, x7
    bl parse_header_end
    cmp x1, #0
    b.eq Lno_header

    ; header end was found, break out of the karmic cycle of reading
    b Lheader_found

Lheader_found:
    mov x8, x1 ;; save the location of the header
    b 2f ;; break from the hell of reading

Lno_header:
    cmp x6, #0 ;; x6 is number of bytes from read() now
    b.ne 1f ; if nonzero, check buffer fill state
    cmp x7, #0 ; if we read nothing,
    b.eq child_end ; go to child_end and silently exit
    b reply_400 ; otherwise if we're done reading but still no header, send 400

1:
    cmp x7, #BUF_SIZE
    b.ge L431

    b read_loop

L431:
    b reply_431
read_failed:
    ; if read was interrupted by a signal, retry instead of exiting. doesn't
    ; affect x7/buf offset.
    cmp x0, #EINTR
    b.eq read_loop
    ;; check if errno is ECONNRESET, ECONNABORTED, ETIMEDOUT, then just
    ;; silently exit if so. otherwise, return server error.
    cb eq, x0, #ECONNRESET, child_end
    cb eq, x0, #ETIMEDOUT, child_end
    cb eq, x0, #ECONNABORTED, child_end
    cb eq, x0, #EPIPE, child_end
    cb eq, x0, #ENETDOWN, child_end
    cb eq, x0, #ENETUNREACH, child_end
    cb eq, x0, #ENETRESET, child_end
    cb eq, x0, #EHOSTDOWN, child_end
    cb eq, x0, #EHOSTUNREACH, child_end
    cb eq, x0, #EAGAIN, L408

    b reply_500
L408:
    b reply_408

2:
    mov x0, x7 ;; restore x0 to be bytes-read
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
    bl streqn
    cmp x0, #1
    b.eq Lget_method

    ;; check if maybe we got a HEAD request instead.
    adr_l x0, buf
    adr_l x1, head_req
    mov x2, head_req_len
    bl streqn
    cmp x0, #1
    b.eq Lhead_method

    ;; hm. maybe it was an OPTIONS request?
    adr_l x0, buf
    adr_l x1, options_req
    mov x2, options_req_len
    bl streqn
    cmp x0, #1
    b.eq Loptions_method

    ;; could be a DELETE request, i *guess*...
    adr_l x0, buf
    adr_l x1, delete_req
    mov x2, delete_req_len
    bl streqn
    cmp x0, #1
    b.eq Ldelete_method

    ;; if it was none, reply 501
    b reply_501

Lget_method:
    mov x20, GET_REQ_ID
    b get

Lhead_method:
    mov x20, HEAD_REQ_ID
    b get

Loptions_method:
    mov x20, OPTIONS_REQ_ID
    b reply_204 ;; reply_* always return to child_end

Ldelete_method:
    mov x20, DELETE_REQ_ID
    b delete

child_end:
    ;; close(clientfd)
    mov x16, SYS_close
    ldr_l x0, clientfd
    svc #0x80

    ;; This is always for children, so let's exit. the parent will loop
    mov x16, SYS_exit
    mov x0, #0
    svc #0x80

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

fatal_exit:
    ;; exit(1)
    mov x16, SYS_exit
    mov x0, #1
    svc #0x80
