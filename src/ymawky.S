;;; ymawky.S -- Web server in ARM64 assembly for MacOS
;;; This file is part of ymawky.
;;; Copyright (C) 2026 imtomt
;;;
;;; ymawky is free software: you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, version 3.
;;;
;;; ymawky is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with this program. If not, see <https://www.gnu.org/licenses/>.

#include "defs.S"

.global _main
.global child_end

.data
.align 3

rcv_timeout:
    .quad RECV_TIMEOUT ; tv_sec
    .quad 0            ; tv_usec

;; timer for total header -- prevent slowloris-like attackers from opening a
;; connection and sending <1 byte/min or something, hogging resources.
;; configured in config.S, HEADER_REQ_TIMEOUT_SECS.
read_timer:
    .quad 0   ; it_interval.tv_sec
    .long 0   ; it_interval.tv_usec
    .long 0   ; -- padding --

    .quad 0   ; it_value.tv_sec
    .long 0   ; it_value.tv_usec
    .long 0   ; -- padding --

.align 2 ;; one is a .word (4 bytes)
one: .word 1

addr:
    .byte 0x02, 0x00             ; AF_INET (2) + padding byte
    .byte 0x1f, 0x90             ; Port 8080, big-endian
    .byte 0x7F, 0x00, 0x00, 0x01 ; 127.0.0.1
    .byte 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 ; padding

get_req:
    .ascii "GET "
.equ get_req_len, . - get_req

put_req:
    .ascii "PUT "
.equ put_req_len, . - put_req

head_req:
    .ascii "HEAD "
.equ head_req_len, . - head_req

options_req:
    .ascii "OPTIONS "
.equ options_req_len, . - options_req

delete_req:
    .ascii "DELETE "
.equ delete_req_len, . - delete_req

brew_req:
    .ascii "BREW "
.equ brew_req_len, . - brew_req

http_: .ascii "HTTP/"
.equ http_len, . - http_

http_1_0: .ascii "HTTP/1.0"
.equ http_1_0_len, . - http_1_0

http_1_1: .ascii "HTTP/1.1"
.equ http_1_1_len, . - http_1_1

host_str: .ascii "Host"
.equ host_str_len, . - host_str

header_503: .ascii "HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\nServer: ymawky\r\n\r\n"
.equ header_503_len, . - header_503

.bss
.align 3
sockfd:             .skip 8
procs:              .skip 8

.text
.align 2

_main:
    mov x28, #0
    ;; did we get an argument
    cmp x0, #1
    b.le skip_argv

    ldr x9, [x1, #8] ; argv[1] pointer
    ldrb w0, [x9] ; first byte of string
    ; if it's less than 'A' (0x41), it's probably a number. so if it is, just
    ; treat it as a port. otherwise, if it's > A (so any letter), let's treat
    ; it as a debug option. pretty hack-y, but supes helpful for debugging, so
    ; we can automatically not fork().
    cmp w0, #'A'
    b.lt 2f

    mov x28, #1
    b skip_argv

2:
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

    ;; debug flag check. skip past the fork stuff in x28 is set
    cbnz x28, 1f
loop:
;; reap any dead child processes
;; note: some (like, one) children may briefly exist as zombies between the
;; child exiting and the next accept() returning. Lreap cleans them up on the
;; next iteration. this is pretty harmless beyond a couple hundred bytes of
;; memory *maybe* being wasted. this should ideally be fixme'd in the future,
;; though.
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

    ldr_l x10, procs
    sub x10, x10, #1
    str_l x10, procs

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

    ;; we check if x28 is set, indicated "d" was passed to cli. if it was, skip
    ;; fork -- it's much easier to debug with lldb if there's no forking :(
    cbnz x28, child

    ldr_l x0, procs
    cmp x0, #MAX_PROCS
    b.lo 8f

    ;; uh-oh, we're at the max processes. let's give a nice, kind, smart, cute,
    ;; lil, friendly 503 :3
    mov x16, SYS_write
    ldr_l x0, clientfd
    adr_l x1, header_503
    mov x2, header_503_len
    svc #0x80
    b 2f ; close n loop!

8:
    ldr_l x0, procs
    add x0, x0, #1
    str_l x0, procs
    ;; fork()
    mov x16, SYS_fork
    svc #0x80
    b.cc 3f ;; fork succeeded, skip the error handling!

    ;; fork failed :( fuck :( decrement proc counter
    ldr_l x0, procs
    sub x0, x0, #1
    str_l x0, procs

    b 2f ; close n loop again

3:
    ;; if we're in the child, go there
    ;; NOTE
    ;; on macos, fork() returns the pid of the child process in x0 in the
    ;; parent process. in the child process, it puts 1 in x1. on linux, fork
    ;; will put 0 in x0 in the child, or the pid in x0 in the parent. so it's
    ;; a bit different. if you're on linux, you've got to change this to
    ;; cmp x0, #0
    cmp x1, #1
    b.eq child
2:
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

    ;; setsockopt() with a SO_RCVTIMEO timeout from config.S, to prevent
    ;; connections from staying open indefinitely
    mov x16, SYS_setsockopt
    ldr_l x0, clientfd
    mov x1, #0xFFFF ; SOL_SOCKET
    mov x2, #0x1006 ; SO_RCVTIMEO = 0x1006
    adr_l x3, rcv_timeout
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

    ;; arm timer before reading
    mov x16, SYS_setitimer
    mov x0, #0 ; ITIMER_REAL
    adr_l x1, read_timer
    mov x2, #HEADER_REQ_TIMEOUT_SECS
    str x2, [x1, #16] ; offset 16 = it_value.tv_sec
    mov x2, #0
    svc #0x80

    ;; set a signal handler for SIGALRM, so we can respond with 408 if the
    ;; connection times out during the header. see the long ass comment in
    ;; put.S for a more detailed explanation of this, since it's extremely
    ;; not-portable. macOS only. yuck. (it shouldn't be too hard to port to
    ;; linux though).
    sub sp, sp, #32
    adr_l x0, L408
    str x0, [sp, #0]  ; sa_handler
    str x0, [sp, #8]   ; sp_tramp = 408 handler. see bigass comment above.
    str wzr, [sp, #16] ; sa_mask = 0
    str wzr, [sp, #20] ; sa_flags = 0

    mov x16, SYS_sigaction
    mov w0, #SIGALRM
    mov x1, sp
    mov x2, #0 ; old action = NULL
    svc #0x80
    add sp, sp, #32
    b.cs L500

    ;; read(client_fd, buffer, buffer_size)
    mov x7, #0
read_loop:
    mov x16, SYS_read
    ldr_l x0, clientfd
    adr_l x1, buf
    add x1, x1, x7 ; account for buffer being partially filled
    mov x22, #BUF_SIZE
    sub x2, x22, x7 ; BUF_SIZE - bytes_read
    svc #0x80
    b.cs read_failed
    mov x22, x0 ; stash number of bytes read() got in x22

    add x7, x7, x0 ; save x0 because parse_header_end clobbers it. cumulatively

    adr_l x0, buf
    mov x1, x7
    bl parse_header_end
    cmp x1, #0
    b.eq Lno_header

    ; header end was found, break out of the karmic cycle of reading
    b Lheader_found

Lheader_found:
    mov x23, x1 ;; end of header index (one byte after \r\n\r\n)
    mov x24, x7 ;; total bytes
    b 2f ;; break from the hell of reading

Lno_header:
    cmp x22, #0 ;; x22 is number of bytes from read() now
    b.ne 1f ; if nonzero, check buffer fill state
    cmp x7, #0 ; if we read nothing,
    b.eq child_end ; go to child_end and silently exit
    b reply_400 ; otherwise if we're done reading but still no header, send 400

1:
    cmp x7, #BUF_SIZE
    b.ge L431

    b read_loop

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

    b reply_500

2:
    ;; disarm timer
    mov x16, SYS_setitimer
    mov x0, #0
    adr_l x1, read_timer
    str xzr, [x1, #16] ; offset 16 = it_value.tv_sec
    mov x2, #0
    svc #0x80

    ;; let's make sure buf is NULL terminated
    adr_l x1, buf
    strb wzr, [x1, x24] ; x24 -> length of bytes read

    ;; this just writes the request to stdout
    mov x2, x23
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, buf
    svc #0x80

    adr_l x0, buf
    mov x1, x23
    bl verify_http_version

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

    ;; oh i know! PUT!
    adr_l x0, buf
    adr_l x1, put_req
    mov x2, put_req_len
    bl streqn
    cmp x0, #1
    b.eq Lput_method

    ;; oh god. it's probably BREW. unfortunately, I'm a teapot, so we can't
    ;; support that method.
    adr_l x0, buf
    adr_l x1, brew_req
    mov x2, brew_req_len
    bl streqn
    cmp x0, #1
    b.eq L418

    ;; if it was none of the above, reply 501
    b reply_501

Lget_method:
    adr_l x0, buf
    mov x1, x23
    b get

Lput_method:
    adr_l x0, buf
    mov x1, x23
    mov x2, x24
    b put

Lhead_method:
    b head

Loptions_method:
    b reply_204 ;; reply_* always returns to child_end

Ldelete_method:
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
    ;; fallthrough
fatal_exit:
    ;; exit(1)
    mov x16, SYS_exit
    mov x0, #1
    svc #0x80


;; verify the header has an HTTP version and that it's 1.1 or 1.0
;; if it's 1.1, ensure we have a Host: field.
;; input
;; x0 -> header buffer
;; x1 -> header length
;;
;; returns
;; nothing, kills process on failure
verify_http_version:
    stp x29, x30, [sp, #-32]!
    stp x20, x21, [sp, #16]

    mov x20, x0
    mov x21, x1

    mov x0, #0
1:
    ldrb w1, [x20, x0]
    cmp w1, #'\r'
    b.ne 2f

    add x0, x0, #1
    cmp x0, x21
    b.ge L400

    ldrb w1, [x20, x0]
    cmp w1, #'\n'
    b.eq 3f

2:
    add x0, x0, #1
    cmp x0, x21
    b.ge L400
    b 1b

3:
    ;; gotta have at least 9 bytes to hold HTTP/1.1\r
    cmp x0, #9
    b.lt L400

    ;; x0 points to the index of the \n in \r\n.
    sub x9, x0, #9
    ;; now it should point to where the "H" would be.

    ;; HTTP/1.1
    add x0, x20, x9
    adr_l x1, http_1_1
    mov x2, http_1_1_len
    bl streqn
    cmp x0, #1
    b.eq Lhttp11

    ;; HTTP/1.0
    add x0, x20, x9
    adr_l x1, http_1_0
    mov x2, http_1_0_len
    bl streqn
    cmp x0, #1
    b.eq Lhttp10

    ;; some other http version?
    add x0, x20, x9
    adr_l x1, http_
    mov x2, http_len
    bl streqn
    cmp x0, #1
    b.eq L505

    ;; oops. none.
    b reply_400

Lhttp11:
    ;; if it's 1.1, we need a Host: field.
    mov x0, x20
    mov x1, x21
    adr_l x2, host_str
    mov x3, host_str_len
    bl get_header_field
    b.cs L400

    b vh_epilogue

Lhttp10:
    ;; HTTP/1.0 doesn't need Host:
    b vh_epilogue

vh_epilogue:
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

L400: b reply_400
L408: b reply_408
L418: b reply_418
L431: b reply_431
L500: b reply_500
L505: b reply_505
