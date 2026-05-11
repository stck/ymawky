#include "defs.S"

.global _main

.align 4

.data
.align 4
cgi_script: .asciz "./logbook"
.align 4
cgi_dir: .asciz "../www/cgi-bin/"
;cgi_dir: .asciz 

.align 4
argv: .quad cgi_script
      .quad 0

;;env0: .asciz "REQUEST_METHOD="
;;env0_val: .asciz "POST"
;;env1: .asciz "CONTENT_LENGTH="
;;env1_val: .asciz "22"
body: .asciz "comment=wow+this+rocks"
.equ body_len, . - body

rm: .asciz "REQUEST_METHOD=POST"
.equ rml, . - rm
cl: .asciz "CONTENT_LENGTH=22"
.equ cll, . - cl

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

    adr_l x1, rm
    mov x2, rml
    bl scev_add_var
    b.cs scev_failure

    adr_l x1, cl
    mov x2, cll
    bl scev_add_var
    b.cs scev_failure

    adr_l x1, gateway_interface
    mov x2, gateway_interface_len
    bl scev_add_var
    b.cs scev_failure

    adr_l x1, server_protocol
    mov x2, server_protocol_len
    bl scev_add_var
    b.cs scev_failure

    adr_l x1, server_software
    mov x2, server_software_len
    bl scev_add_var
    b.cs scev_failure

    adr_l x1, path
    mov x2, path_len
    bl scev_add_var
    b.cs scev_failure

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

scev_add_var:
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
_main:
pre_fork:
    adr_l x0, env_var_str_buf
    adr_l x1, env_var_ptr_buf
    bl set_constant_env_vars
    ; envp is built already, just static for now
    
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
    mov x16, SYS_close
    ldr_l w0, cgi_stdin_r
    svc #0x80
    b.cs error
    ;; close stdout_w
    mov x16, SYS_close
    ldr_l w0, cgi_stdout_w
    svc #0x80
    b.cs error

    mov x16, SYS_write
    ldr_l w0, cgi_stdin_w
    adr_l x1, body
    mov x2, body_len
    svc #0x80
    b.cs error


    ;; this is a boolean. have we already output a header? 0 = no, 1 = yes
    mov x19, #0
Lread_loop:
    mov x16, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    mov x2, cgi_buf_size
    svc #0x80
    b.cs error
    cbz x0, Lloop_end

    mov x20, x0  ; save read length

    ;; skip this bit if we've already sent a header
    cbnz x19, Lskip_header

    mov x0, #1
    adr_l x1, cgi_header
    mov x2, cgi_header_len
    bl write_all

    adr_l x21, cgi_buf
    mov x0, x21
    mov x1, x20
    bl parse_header_end

    mov x22, x1
    cbnz x22, 1f

    mov x0, #1
    adr_l x1, cgi_noscriptheader_end
    mov x2, cgi_noscriptheader_end_len
    bl write_all
    b 2f
bp1:
1:
    mov x0, #1
    mov x1, x21
    mov x2, x22
    bl write_all

    add x21, x21, x22
    sub x20, x20, x22
    ;; skip past the header bytes in the response from the cgi script
    ;add x21, x21, x22
    ;sub x20, x20, x22
    ;; if the CGI script only sent over a header for some reason, we gotta try
    ;; to read again...
    ;cmp x20, #0
    ;b.ls Lread_loop

    ;mov x0, #1
    ;mov x1, x21
    ;mov x2, x22 ; from parse_header_end
    ;bl write_all
2:
    ; mark that we have written the header, so this loop doesn't reiterate.
    mov x19, #1

Lskip_header:
    ;mov x16, SYS_write
    ;mov x0, #1
    ;adr_l x1, cgi_buf
    ;mov x2, x20
    ;svc #0x80
    ;b.cs error
    mov x0, #1
    ;adr_l x1, cgi_buf
    mov x1, x21
    mov x2, x20
    bl write_with_chunk_length


Lloop_end:
    mov x16, SYS_wait4
    mov x0, #-1           ; any child
    adr_l x1, status      ; where to store wstatus (allocate 4 bytes in .bss)
    mov x2, #0            ; options
    mov x3, #0            ; rusage = NULL
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

fuck:
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
    ;; x0 is already errno
    mov x16, SYS_exit
    svc #0x80
