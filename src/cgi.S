#include "defs.S"

.global _main

.align 4

.data
.align 4
cgi_script: .asciz "logbook"
.align 4
cgi_dir: .asciz "../www/cgi-bin/"


;env0: .asciz "REQUEST_METHOD=GET"
;env1: .asciz "PATH_INFO=/json"

.align 4
argv: .quad cgi_script
      .quad 0

env0: .asciz "REQUEST_METHOD=POST"
env1: .asciz "CONTENT_LENGTH=22"
body: .asciz "comment=wow+this+sucks"
.equ body_len, . - body

.align 4
envp:
    .quad env0
    .quad env1
    .quad 0

.bss
.align 4
cgi_stdin_r:  .skip 4
cgi_stdin_w:  .skip 4
cgi_stdout_r: .skip 4
cgi_stdout_w: .skip 4
status: .skip 4
.equ cgi_buf_size, 1024
cgi_buf: .skip cgi_buf_size

.text
.align 2
_main:
pre_fork:
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

    mov x16, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    mov x2, cgi_buf_size
    svc #0x80
    b.cs error
    mov x20, x0  ; save read length

    mov x16, SYS_write
    mov x0, #1
    adr_l x1, cgi_buf
    mov x2, x20
    svc #0x80
    b.cs error

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

    ;; FINALLY we can FUCKING EXECVE
    mov x16, SYS_execve
    adr_l x0, cgi_script
    adr_l x1, argv
    adr_l x2, envp
    svc #0x80

    ;; execve() is supposed to replace this child process with that one. if we
    ;; return here after execve, something has gone horribly wrong... so just
    ;; consider it an error
    b error

error:
    ;; x0 is already errno
    mov x16, SYS_exit
    svc #0x80
