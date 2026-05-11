#include "defs.S"

.global cgi

.align 4

.data
.align 4
cgi_script: .asciz "./logbook"
.align 4
cgi_dir: .asciz "www/cgi-bin/"
;cgi_dir: .asciz 

.align 4
argv: .quad cgi_script
      .quad 0

body: .asciz "comment=wow+this+rocks"
.equ body_len, . - body

;rm: .asciz "REQUEST_METHOD=POST"
;.equ rml, . - rm
;cl: .asciz "CONTENT_LENGTH=22"
;.equ cll, . - cl

;; constant env vars
gateway_interface: .asciz "GATEWAY_INTERFACE=CGI/1.1"
.equ gateway_interface_len, . - gateway_interface

server_protocol: .asciz "SERVER_PROTOCOL=HTTP/1.1"
.equ server_protocol_len, . - server_protocol

server_software: .asciz "SERVER_SOFTWARE=ymawky"
.equ server_software_len, . - server_software

path: .asciz "PATH=/usr/bin:/bin"
.equ path_len, . - path

;; variable env vars
request_method: .ascii "REQUEST_METHOD="
.equ request_method_len, . - request_method

get_str:     .ascii "GET"
.equ get_len,     . - get_str
head_str:    .ascii "HEAD"
.equ head_len,    . - head_str
options_str: .ascii "OPTIONS"
.equ options_len, . - options_str
delete_str:  .ascii "DELETE"
.equ delete_len,  . - delete_str
put_str:     .ascii "PUT"
.equ put_len,     . - put_str
post_str:    .ascii "POST"
.equ post_len,    . - post_str

script_name: .ascii "SCRIPT_NAME="
.equ script_name_len, . - script_name

query_string: .ascii "QUERY_STRING="
.equ query_string_len, . - query_string

content_length: .ascii "CONTENT_LENGTH="
.equ content_length_len, . - content_length

content_type: .ascii "CONTENT_TYPE="
.equ content_type_len, . - content_type

http_host: .ascii "HTTP_HOST="
.equ http_host_len, . - http_host

cgi_header: .ascii "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\nAllow: GET, HEAD, OPTIONS, DELETE, PUT\r\nAccept-Ranges: bytes\r\nServer: ymawky\r\n"
.equ cgi_header_len, . - cgi_header

;; if the fuckin cgi script doesn't send over a header, let's just like. make
;; sure we at least send this, and the \r\n\r\n to end the header.
cgi_noscriptheader_end: .ascii "Content-Type: text/html; charset=utf-8; shit\r\n\r\n"
.equ cgi_noscriptheader_end_len, . - cgi_noscriptheader_end

chunked_content_end: .ascii "0\r\n\r\n"
.equ chunked_content_end_len, . - chunked_content_end

oops: .asciz "shouldnt be here\n"
.equ oopsl, . - oops

.bss
.align 4
cgi_stdin_r:  .skip 4
cgi_stdin_w:  .skip 4
cgi_stdout_r: .skip 4
cgi_stdout_w: .skip 4
status: .skip 4
.equ cgi_buf_size, 1024
cgi_buf: .skip cgi_buf_size

.equ env_var_str_buf_size, 4096
env_var_str_buf: .skip env_var_str_buf_size

.equ env_var_ptr_buf_size, 512
env_var_ptr_buf: .skip env_var_ptr_buf_size

.text
.align 2
set_constant_env_vars:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    mov x19, x0 ; string buffer
    mov x20, x1 ; pointer buffer

    mov x21, #0 ; index into string buffer
    mov x22, #0 ; index into pointer buffer
    mov x23, env_var_str_buf_size
    mov x24, env_var_ptr_buf_size

    ;adr_l x1, cl
    ;mov x2, cll
    ;bl scev_add_const_var
    ;b.cs scev_failure

    adr_l x1, gateway_interface
    mov x2, gateway_interface_len
    bl scev_add_const_var
    b.cs scev_failure

    adr_l x1, server_protocol
    mov x2, server_protocol_len
    bl scev_add_const_var
    b.cs scev_failure

    adr_l x1, server_software
    mov x2, server_software_len
    bl scev_add_const_var
    b.cs scev_failure

    adr_l x1, path
    mov x2, path_len
    bl scev_add_const_var
    b.cs scev_failure

    adr_l x1, query_string
    mov x2, query_string_len
    ldr_l x3, query_str ; from data.S. TODO get better names
    ldr_l x4, query_len
    bl scev_add_kv_var

    ;; content length and content type are only for PUT/POST
    ldr_l x3, request_id
    cmp x3, #PUT_ID
    b.eq 1f
    cmp x3, #POST_ID
    b.eq 1f
    ;; if it's not PUT or POST, skip these
    b 2f
1:
    mov x25, x0 ; save current pointer

    adr_l x0, buf ; this is the header from the clients req. i've gotta rename
    ldr_l x1, header_len
    bl parse_content_length
    b.cs scev_failure

    ;; x0 should be content length from parse_content_length now.
    bl itoa
    ;; now x0 -> pointer to start of itoa'd string,
    ;;     x1 -> length of said string
    mov x3, x0
    mov x4, x1
    mov x0, x25 ; NOW we restore the previously-saved pointer for memcpy
    adr_l x1, content_length
    mov x2, content_length_len
    bl scev_add_kv_var
2:
    ;; there's gotta be a better way to do this... oh well. that's a problem
    ;; for future tomt.
    ldr_l x3, request_id
    cmp x3, #GET_ID
    b.eq 1f
    cmp x3, #HEAD_ID
    b.eq 2f
    cmp x3, #OPTIONS_ID
    b.eq 3f
    cmp x3, #DELETE_ID
    b.eq 4f
    cmp x3, #PUT_ID
    b.eq 5f
    cmp x3, #POST_ID
    b.eq 6f

    ;; if none, just fall through to GET i guess. should really be a 500 tho
1:
    adr_l x3, get_str
    mov x4, get_len
    b 9f
2:
    adr_l x3, head_str
    mov x4, head_len
    b 9f
3:
    adr_l x3, options_str
    mov x4, options_len
    b 9f
4:
    adr_l x3, delete_str
    mov x4, delete_len
    b 9f
5:
    adr_l x3, put_str
    mov x4, put_len
    b 9f
6:
    adr_l x3, post_str
    mov x4, post_len
    ;; fallthrough
9:
    adr_l x1, request_method
    mov x2, request_method_len
    bl scev_add_kv_var

    str xzr, [x20, x22]
    b scev_epilogue

scev_failure:
    cmp xzr, xzr
    b 1f
scev_epilogue:
    cmn xzr, xzr
1:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

;; x0 -> destination for memcpy
;; x1 -> key string
;; x2 -> key string length
;; x3 -> value string
;; x4 -> value string length
scev_add_kv_var:
    stp x29, x30, [sp, #-32]!
    stp x25, x26, [sp, #16]

    mov x25, x3
    mov x26, x4

    cmp x22, x24
    b.hs 2f

    add x21, x21, x2
    cmp x21, x23
    b.hs 2f

    str x0, [x20, x22]
    add x22, x22, #8

    bl memcpy
    ;; memcpy advances x0

    add x21, x21, x26
    cmp x21, x23
    b.hs 2f

    mov x1, x25
    mov x2, x26
    bl memcpy

    add x21, x21, #1
    cmp x21, x23
    b.hs 2f
    strb wzr, [x0], #1

1:
    cmn xzr, xzr
    b 3f
2:
    cmp xzr, xzr
3:
    ldp x25, x26, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

scev_add_const_var:
    stp x29, x30, [sp, #-16]!
    cmp x22, x24
    b.hs 2f

    add x21, x21, x2
    cmp x21, x23
    b.hs 2f

    str x0, [x20, x22]
    add x22, x22, #8

    ;; x0, x1, and x2 are set by the caller
    bl memcpy
1:
    cmn xzr, xzr
    b 3f
2:
    cmp xzr, xzr
3:
    ldp x29, x30, [sp], #16
    ret

.align 2
cgi:
pre_fork:
    adr_l x0, env_var_str_buf
    adr_l x1, env_var_ptr_buf
    bl set_constant_env_vars
    ; envp is built already, just static for now
 fuck:   
    ;; SYS_pipe()
    ;; NOTE: the pipe() syscall, unlike the libc wrapper, takes no arguments
    mov x16, #SYS_pipe
    svc #0x80
    b.cs error
    str_l w0, cgi_stdin_r
    str_l w1, cgi_stdin_w

    mov x16, #SYS_pipe
    svc #0x80
    b.cs error
    str_l w0, cgi_stdout_r
    str_l w1, cgi_stdout_w

about_to_fork:
    ;; SYS_fork()
    mov x16, SYS_fork
    svc #0x80
    b.cs error ;; just bail if fork fails

    cmp x1, #1 ; are we the child?
    b.eq cgi_child
    ;; if not, then we're the...
cgi_parent:
    ;; we can close() the unused fds
    ;; close stdin_r
    mov x28, #1
    mov x16, SYS_close
    ldr_l w0, cgi_stdin_r
    svc #0x80
    b.cs error
    ;; close stdout_w
    mov x28, #2
    mov x16, SYS_close
    ldr_l w0, cgi_stdout_w
    svc #0x80
    b.cs error

    ldr_l x0, request_id
    cb eq, x0, #PUT_ID, 1f
    cb eq, x0, #POST_ID, 1f
    b 2f
1:
    mov x28, #3
    adr_l x0, buf
    ldr_l x1, header_len
    bl parse_header_end
    cbz x1, error
    mov x20, x1

    mov x28, #4
    adr_l x0, buf
    ldr_l x1, header_len
    bl parse_content_length
    b.cs error

    ldr_l x1, header_len
    mov x2, x20
    ;; x0 = Content-Length header field
    ;; x1 = total read from client in ymawky.S
    ;; x2 = index at end of header, everything after is body
    mov x23, x0 ; x23 = content length, total body expected
    sub x24, x1, x2 ; x24 = body bytes already in buf

    cmp x24, x23
    csel x24, x23, x24, hi ; if x24 > x23, x24 = x23

    ;; nothing in buf, so skip to the loop
    cbz x24, Lforward_loop

    ;; write whatever body is already present in buf, to cgi_stdin_w
    mov x28, #5
    ldr_l w0, cgi_stdin_w
    adr_l x1, buf
    add x1, x1, x20
    mov x2, x24
    bl write_all
    b.cs error

Lforward_loop:
    ;; remaining = content_length - bytes_so_far
    sub x25, x23, x24
    cbz x25, Lforward_done ; nothin more to forward!

    ;; read min(remaining, cgi_buf_size) bytes from clientfd
    mov x28, #6
    mov x16, SYS_read
    ldr_l w0, clientfd
    adr_l x1, cgi_buf
    mov x2, cgi_buf_size
    cmp x2, x25
    csel x2, x2, x25, lo
    svc #0x80
    b.cs error
    cbz x0, error ; client closed? before sending full body? dumb. error.
    mov x26, x0 ; x26 = bytes just read

    ;; now forward those bytes to cgi_stdin_w
    mov x28, #7
    ldr_l w0, cgi_stdin_w
    adr_l x1, cgi_buf
    mov x2, x26
    bl write_all

    add x24, x24, x26
    b Lforward_loop

Lforward_done:
    mov x28, #8
    ;; close cgi_stdin_w to signal EOF
    mov x16, SYS_close
    ldr_l w0, cgi_stdin_w
    svc #0x80
    b.cs error
2:
    ;mov x16, SYS_write
    ;ldr_l w0, cgi_stdin_w
    ;adr_l x1, body
    ;mov x2, body_len
    ;svc #0x80
    ;b.cs error

    ;; this is a boolean. have we already output a header? 0 = no, 1 = yes
    mov x19, #0
Lread_loop:
    mov x28, #9
    mov x16, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    mov x2, cgi_buf_size
    svc #0x80
    b.cs 1f
    cbz x0, Lloop_end

    b 2f
1:
    cmp x0, #EINTR
    b.eq Lread_loop
    mov x28, #99
    b error
2:
    mov x20, x0  ; save read length
    adr_l x21, cgi_buf

    ;; skip this bit if we've already sent a header
    cbnz x19, Lskip_header

    mov x28, #10
    ;mov x0, #1
    ldr_l x0, clientfd
    adr_l x1, cgi_header
    mov x2, cgi_header_len
    bl write_all

    mov x0, x21
    mov x1, x20
    bl parse_header_end

    mov x22, x1
    cbnz x22, 1f

    mov x28, #11
    ;mov x0, #1
    ldr_l x0, clientfd
    adr_l x1, cgi_noscriptheader_end
    mov x2, cgi_noscriptheader_end_len
    bl write_all
    b 2f
1:
    mov x28, #12
    ;mov x0, #1
    ldr_l x0, clientfd
    mov x1, x21
    mov x2, x22
    bl write_all

    add x21, x21, x22
    sub x20, x20, x22
    ;; if the CGI script only sent over a header for some reason, we gotta try
    ;; to read again...
    cmp x20, #0
    b.ls Lread_loop

2:
    ; mark that we have written the header, so this loop doesn't reiterate.
    mov x19, #1

Lskip_header:
    mov x28, #13
    ;mov x0, #1
    ldr_l x0, clientfd
    mov x1, x21
    mov x2, x20
    bl write_with_chunk_length

    b Lread_loop

Lloop_end:
guck:
    mov x28, #14
    ;mov x0, #1
    ldr_l x0, clientfd
    adr_l x1, chunked_content_end
    mov x2, chunked_content_end_len
    bl write_all

    mov x16, SYS_wait4
    mov x0, #-1 ; any child
    adr_l x1, status ; where to store wstatus
    mov x2, #0 ; options
    mov x3, #0 ; rusage = NULL
    svc #0x80

    mov x16, SYS_exit
    mov x0, #0
    svc #0x80

;; ok fine we're a kid! yay! *plays on a swingset*
cgi_child:
    ;; we've gotta close() unused fds
    ;; close stdin_w
    mov x16, SYS_close
    ldr_l w0, cgi_stdin_w
    svc #0x80
    b.cs error
    ;; close stdout_r
    mov x16, SYS_close
    ldr_l w0, cgi_stdout_r
    svc #0x80
    b.cs error

    ;; duplicate the filedescriptors to be actually stdin/out
    mov x16, SYS_dup2
    ldr_l w0, cgi_stdin_r ; pipe fd
    mov x1, #0 ; stdin
    svc #0x80
    b.cs error

    mov x16, SYS_dup2
    ldr_l w0, cgi_stdout_w ; pipe fd
    mov x1, #1 ; stdout
    svc #0x80
    b.cs error

    ;; now that cgi_stdin/out_r/w has been duplicated to just stdin/out, we can
    ;; close the fds from pipe.
    mov x16, SYS_close
    ldr_l w0, cgi_stdin_r
    svc #0x80
    b.cs error
    
    mov x16, SYS_close
    ldr_l w0, cgi_stdout_w
    svc #0x80
    b.cs error

    ;; we gotta chdir into the right directory
    mov x16, #12 ; SYS_chdir
    adr_l x0, cgi_dir
    svc #0x80
    b.cs error

    ;; FINALLY we can FUCKING EXECVE
    mov x16, SYS_execve
    adr_l x0, cgi_script
    adr_l x1, argv
    ;adr_l x2, envp
    adr_l x2, env_var_ptr_buf
    svc #0x80

    ;; execve() is supposed to replace this child process with that one. if we
    ;; return here after execve, something has gone horribly wrong... so just
    ;; consider it an error
    mov x0, #99
    b error

error:
    mov x20, x0
    mov x16, SYS_write
    mov x0, #1
    adr_l x1, oops
    mov x2, oopsl
    svc #0x80
    mov x0, x20
    ;; x0 is already errno
    mov x16, SYS_exit
    svc #0x80
