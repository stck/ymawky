#include "defs.S"


;;; TODO TODO TODO
;;
;; 1. Rather than execute any executable file as a CGI script, parse the path.
;;    if it's a request for DOCROOT/CGI_DIR, check for executability. if exec-
;;    able, exec it as a CGI. otherwise, just serve the request.
;; 2. Fix up code stuff
;; 3. Parse filename_str to get file-to-execve. might need to implement some
;;    kind of basename() function. since we cant like:
;;      chdir("www/cgi-bin/");
;;      execve("www/cgi-bin/epicscriptz");
;;
;;; TODO TODO TODO


.global cgi
.global check_cgi_path

.align 4

.data
.align 4
cgi_dir: .ascii DOCROOT
         .ascii CGI_DIR
.equ cgi_dir_len, . - cgi_dir
cgi_dir_len_val: .quad cgi_dir_len

.align 4
argv: .quad 0
      .quad 0

;; constant env vars
gateway_interface: .asciz "GATEWAY_INTERFACE=CGI/1.1"
.equ gateway_interface_len, . - gateway_interface

server_protocol: .asciz "SERVER_PROTOCOL=HTTP/1.1"
.equ server_protocol_len, . - server_protocol

server_software: .asciz "SERVER_SOFTWARE=ymawky"
.equ server_software_len, . - server_software

path: .asciz "PATH=/usr/bin:/bin"
.equ path_len, . - path

path_info: .asciz "PATH_INFO=\0"
.equ path_info_len, . - path_info

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


;; Stuff for the HTTP header
cgi_server_headers: .ascii "Server: ymawky\r\n"
                    .ascii "Connection: close\r\n"
                    .ascii "X-Content-Type-Options: nosniff\r\n"
.equ cgi_server_headers_len, . - cgi_server_headers

cgi_status: .ascii "HTTP/1.1 "
.equ cgi_status_len, . - cgi_status

;; CGI script should send it's own status, but just in case it dooesn't
cgi_200: .ascii "200 OK\r\n"
.equ cgi_200_len, . - cgi_200

;;cgi_conn_close: .ascii "Connection: close\r\n"
;;.equ cgi_conn_close_len, . - cgi_conn_close

;;cgi_server: .ascii "Server: ymawky\r\n"
;;.equ cgi_server_len, . - cgi_server

;;cgi_nosniff: .ascii "X-Content-Type-Options: nosniff\r\n"
;;.equ cgi_nosniff_len, . - cgi_nosniff


;; Various linefeeds and such
crlf: .ascii "\r\n"
.equ crlf_len, . - crlf

header_end_crlf: .ascii "\r\n\r\n"
.equ header_end_crlf_len, . - header_end_crlf
header_end_lflf: .ascii "\n\n"
.equ header_end_lflf_len, . - header_end_lflf

;; Header fields from the CGI script to not forward in our response
;; we check with streqn_i, 
cgiscr_status: .ascii "status:"
.equ cgiscr_status_len, . - cgiscr_status

cgiscr_conn: .ascii "connection:"
.equ cgiscr_conn_len, . - cgiscr_conn

cgiscr_content_type: .ascii "content-type:"
.equ cgiscr_content_type_len, . - cgiscr_content_type


.bss
.align 4
cgi_stdin_r:  .skip 4
cgi_stdin_w:  .skip 4
cgi_stdout_r: .skip 4
cgi_stdout_w: .skip 4
status: .skip 4
.equ cgi_buf_size, BUF_SIZE
cgi_buf: .skip cgi_buf_size

.equ env_var_str_buf_size, 4096
env_var_str_buf: .skip env_var_str_buf_size

.equ env_var_ptr_buf_size, 512
env_var_ptr_buf: .skip env_var_ptr_buf_size

.align 3
.equ script_name_buf_len, 256
script_name_buf: .skip script_name_buf_len
.align 3
.equ script_path_buf_len, 4096
script_path_buf: .skip script_path_buf_len

.text
.align 2
;; is filename_str a file within CGI_DIR?
;; input
;; none -- uses global data
;;
;; output
;; clears carry if path IS in CGI_DIR. clears carry if path is NOT in CGI_DIR.
check_cgi_path:
    stp x29, x30, [sp, #-16]!

    ;; if filename len is shorter than cgi_dir_len - 1, it's definitely not
    ;; in cgi_dir/.
    ldr_l x0, filename_len
    mov x2, cgi_dir_len
    sub x2, x2, #1 ; account for the possible missing /
    cmp x0, x2
    b.lo Lnot_cgi_file

    ;; check if it matches CGI_DIR/, with the slash
    ldr_l x0, filename_str
    adr_l x1, cgi_dir
    mov x2, cgi_dir_len
    bl streqn_i
    cbz x0, 1f
    ;; if we're here, x0 was nonzero, so it was a match. CGI path.
    b Lcgi_file
1:
    ;; check if it matches CGI_DIR, without the slash
    ldr_l x0, filename_str
    adr_l x1, cgi_dir
    mov x2, cgi_dir_len
    sub x2, x2, #1 ; account for possible missing /
    bl streqn_i
    cbz x0, Lnot_cgi_file ; ok, it wasnt CGI_DIR/ or CGI_DIR, so its not a match
    ;; if they DO match, fallthrough
Lcgi_file:
    cmn xzr, xzr ; clear carry
    b Lccp_epilogue

Lnot_cgi_file:
    cmp xzr, xzr ; set carry
    ;; fallthrough
Lccp_epilogue:
    ldp x29, x30, [sp], #16
    ret


.align 2
;; set the environmental vars used for CGI scripts
;; input
;; x0 -> env_var_str_buf
;; x1 -> env_var_ptr_buf
;;
;; output
;; nothing -- modifies env_var_[str/ptr]_buf
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

    ;; GATEWAY_INTERFACE=CGI/1.1
    adr_l x1, gateway_interface
    mov x2, gateway_interface_len
    bl scev_add_const_var
    b.cs scev_failure

    ;; SERVER_PROTOCOL=HTTP/1.1
    adr_l x1, server_protocol
    mov x2, server_protocol_len
    bl scev_add_const_var
    b.cs scev_failure

    ;; SERVER_SOFTWARE=ymawky
    adr_l x1, server_software
    mov x2, server_software_len
    bl scev_add_const_var
    b.cs scev_failure

    ;; PATH=/bin:/usr/bin (so CGI scripts can execute things)
    adr_l x1, path
    mov x2, path_len
    bl scev_add_const_var
    b.cs scev_failure

    ;; PATH_INFO=(null)
    adr_l x1, path_info
    mov x2, path_info_len
    bl scev_add_const_var
    b.cs scev_failure

    ;; QUERY_STRING=query_str
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
    ;; CONTENT_LENGTH=(content-length from header)
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
    ;; REQUEST_METHOD=GET/PUT/POST/whatever blah blah blah
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

    ;; bounds check
    add x21, x21, x2
    cmp x21, x23
    b.hs 2f

    ;; store pointer to current location in env_var_ptr_buf
    str x0, [x20, x22]
    add x22, x22, #8

    ;; store KEY= string in env_var_str_buf
    bl memcpy
    ;; memcpy advances x0

    ;; bounds check again
    add x21, x21, x26
    cmp x21, x23
    b.hs 2f

    ;; store value string in env_var_str_buf
    mov x1, x25
    mov x2, x26
    bl memcpy

    ;; bounds check and NULL terminate string
    add x21, x21, #1
    cmp x21, x23
    b.hs 2f
    strb wzr, [x0], #1

1:
    cmn xzr, xzr ; clear carry
    b 3f
2:
    cmp xzr, xzr ; set carry
3:
    ldp x25, x26, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

scev_add_const_var:
    stp x29, x30, [sp, #-16]!
    cmp x22, x24
    b.hs 2f

    ;; bounds check
    add x21, x21, x2
    cmp x21, x23
    b.hs 2f

    ;; store pointer in env_var_ptr_buf
    str x0, [x20, x22]
    add x22, x22, #8

    ;; x0, x1, and x2 are set by the caller
    ;; store string in env_var_str_buf
    bl memcpy
1:
    cmn xzr, xzr ; clear carry
    b 3f
2:
    cmp xzr, xzr ; set carry
3:
    ldp x29, x30, [sp], #16
    ret

.align 2
;; main CGI function
;; inputs
;; none -- uses global data
;;
;; returns
;; nothing -- sends reply to client and exits
cgi:
pre_fork:
    ldr_l x0, filename_str
    bl stat_path
    cbnz x0, Lhfs_error

    ;; cgi is only files. shouldn't be directories. no dir listing on cgi-bin,
    ;; sorry :(
    cmp w1, #S_IFREG
    b.ne L403
    
    ;; x3 is a boolean, is file executable? 0 means no. file isn't executable, 
    ;; that's a problem on the servers end. why the HELL do you have
    ;; nonexecutable files in the CGI script directory, huh?! go fix that.
    cbz x3, L500

    adr_l x0, env_var_str_buf
    adr_l x1, env_var_ptr_buf
    bl set_constant_env_vars

    bl get_script_path_elements
    b.cs Lerror

    adr_l x0, script_name_buf
    str_l x0, argv

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

    ldr_l x0, request_id
    cb eq, x0, #PUT_ID, 1f
    cb eq, x0, #POST_ID, 1f
    b Lnothing_to_forward ; skip this whole mess if it's not PUT or POST
1:
    ;; ok, if we're here, it's a PUT or POST request. those require a body.
    ;; bodies require content length. we need to forward the body from the orig
    ;; request to the cgi script's stdin

    ;; make sure we actually have a valid header.
    adr_l x0, buf
    ldr_l x1, header_len
    bl parse_header_end
    cbz x1, error
    mov x20, x1

    ;; get content length
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
    ldr_l w0, cgi_stdin_w
    adr_l x1, cgi_buf
    mov x2, x26
    bl write_all

    add x24, x24, x26
    b Lforward_loop

Lforward_done:
    ;; close cgi_stdin_w to signal EOF
    mov x16, SYS_close
    ldr_l w0, cgi_stdin_w
    svc #0x80
    b.cs error

Lnothing_to_forward:
    ;; this is a boolean. have we already output a header? 0 = no, 1 = yes
    mov x19, #0
    mov x20, #0
Lread_loop:
    ;; read loop will send us to either Lheader_read_loop or Lbody_read_loop,
    ;; depending on the value of x19. since both functions call read(), and
    ;; b.cs Lread_failed if read fails, and Lread_failed might branch *back*
    ;; to Lread_loop, we have to know which path we're currently at. that's
    ;; why we track x19
    cbz x19, Lheader_read_loop
    b Lbody_read_loop

Lheader_read_loop:
    mov x16, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    add x1, x1, x20 ; append to cgi_buf, rather than overwriting
    mov x2, cgi_buf_size
    sub x2, x2, x20 ; reduce buf_size by bytes already read
    cbz x2, L502 ; if we've filled the whole buffer, gotta give a 502.
                 ; BAD gateway!
    svc #0x80
    b.cs Lread_failed
    cbz x0, L502 ; EOF before terminator also gives 502.

    mov x22, x0
    add x20, x20, x0

    adr_l x0, cgi_buf
    mov x1, x20
    bl parse_cgi_header_end
    cbz x1, Lread_loop

    ;; if we got here, then we've found a header block. gotta output that.
    mov x22, x1 ; x22 = body start offset. save it!
    mov x21, x2

    ;; check for Status:
    adr_l x0, cgi_buf
    mov x1, x22 ; header length
    adr_l x2, cgiscr_status
    mov x3, cgiscr_status_len
    bl get_cgi_header_field
    ;; now x0/x1 contain pointer/length of value, or carry set if not found
    b.cs Ldefault_status
    mov x23, x0 ; save pointer
    mov x24, x1 ; save length

    ;; "HTTP/1.1 "
    ldr_l x0, clientfd
    adr_l x1, cgi_status
    mov x2, cgi_status_len
    bl write_all

    ;; value from cgi header
    ldr_l x0, clientfd
    mov x1, x23
    mov x2, x24
    bl write_all

    ;; "\r\n"
    ldr_l x0, clientfd
    adr_l x1, crlf
    mov x2, crlf_len
    bl write_all

    b Lstatus_done

Ldefault_status:
    ;; "HTTP/1.1 "
    ldr_l x0, clientfd
    adr_l x1, cgi_status
    mov x2, cgi_status_len
    bl write_all

    ;; "200 OK\r\n"
    ldr_l x0, clientfd
    adr_l x1, cgi_200
    mov x2, cgi_200_len
    bl write_all
    ;; fallthrough
Lstatus_done:
    ;; phew. ok. now we gotta check for Content-Type
    adr_l x0, cgi_buf
    mov x1, x22
    adr_l x2, cgiscr_content_type
    mov x3, cgiscr_content_type_len
    bl get_cgi_header_field
    b.cc Lgot_ct
    ;; not found... if there's a body, that's bad. Content-Type is required
    ;; if there's a body! so we gotta check.
    sub x3, x20, x22
    cbnz x3, L502

Lgot_ct:
    ;; first, we gotta print our constant server header fields...
    ldr_l x0, clientfd
    adr_l x1, cgi_server_headers
    mov x2, cgi_server_headers_len
    bl write_all

    ;; now, we forward all of the script's headers, minus a couple:
    ;; the function here doesn't send Status: or Connection: header fields,
    ;; we do that on our own above.
    sub x1, x22, x21
    adr_l x0, cgi_buf
    ldr_l x2, clientfd
    bl forward_headers_from_script

    ;; finally we can send an \r\n and be done with it.
    ldr_l x0, clientfd
    adr_l x1, crlf
    mov x2, #2
    bl write_all

    ;; if we have any leftover bytes from the body, write em out now
    sub x2, x20, x22 ; leftover length = total - header length
    cbz x2, 1f ; if there's nothing leftover, skip this
    ldr_l x0, clientfd
    adr_l x1, cgi_buf
    add x1, x1, x22 ; cgi_buff + header length offset
    bl write_all

1:
    mov x19, #1
Lbody_read_loop:
    ;; stream any remaining body content from cgi script's stdout, to clientfd
    mov x16, SYS_read
    ldr_l w0, cgi_stdout_r
    adr_l x1, cgi_buf
    mov x2, cgi_buf_size
    svc #0x80
    b.cs Lread_failed
    cbz x0, Lloop_end ; hit EOF? we're donezo (in a good way)

    mov x2, x0
    ldr_l x0, clientfd
    adr_l x1, cgi_buf
    bl write_all

    b Lbody_read_loop

Lread_failed:
    cmp x0, #EINTR
    b.eq Lread_loop

    ;; otherwise, it's an error :(
    b error

Lloop_end:
    mov x16, SYS_wait4
    mov x0, #-1 ; any child
    adr_l x1, status ; where to store wstatus
    mov x2, #0 ; options
    mov x3, #0 ; rusage = NULL
    svc #0x80

    b child_end


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
    adr_l x0, script_path_buf
    svc #0x80
    b.cs error

    ;; FINALLY we can FUCKING EXECVE
    mov x16, SYS_execve
    adr_l x0, script_name_buf
    adr_l x1, argv
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

;; find cgi header end, since cgi headers can use either \r\n\r\n or \n\n
;; NOTE for CGI response parsing ONLY. DONT USE ON CLIENT REQUESTS. for
;; parsing the original header from the client, use parse_header_end (parse.S)
;; inputs
;; x0 -> buffer (header, possibly has body trailing)
;; x1 -> length of buffer
;;
;; returns
;; x1 -> index of the first byte AFTER the terminator, or 0 if none found
;; x2 -> length of half of the terminator, 2 (\r\n\r\n) or 1 (\n\n)
parse_cgi_header_end:
    mov x5, #0
    mov x6, #0
    mov x7, #0

    adr_l x2, header_end_crlf
    adr_l x8, header_end_lflf

Lpche_loop:
    cmp x5, x1
    b.hs Lpche_no_end_found

    ldrb w3, [x0, x5] ; current input byte
    ldrb w4, [x2, x6]
    cmp w3, w4
    b.eq Lpche_crlf_correct
    b Lpche_crlf_incorrect

Lpche_crlf_correct:
    add x6, x6, #1 ; increment local index into \r\n\r\n
    cmp x6, #4 ; length of \r\n\r\n
    b.lo Lpche_check_lflf ; it could be \n\n instead of \r\n\r\n, so check

    mov x2, #2 ; matched \r\n\r\n. we want to trim the second half, so ret 2
    b Lpche_end_found

Lpche_crlf_incorrect:
    mov x6, #0 ; reset index into header_end_crlf
    cmp w3, #'\r'
    b.ne Lpche_check_lflf
    mov x6, #1
    ;; fallthrough
Lpche_check_lflf:
    ldrb w4, [x8, x7]
    cmp w3, w4
    b.eq Lpche_lflf_correct
    b Lpche_lflf_incorrect

Lpche_lflf_correct:
    add x7, x7, #1
    cmp x7, #2 ; length of \n\n
    b.lo Lpche_advance

    mov x2, #1 ; matched \n\n. we want to trim the second half, so ret 2
    b Lpche_end_found

Lpche_lflf_incorrect:
    mov x7, #0 ; reset index into header_end_lflf
    ;; fallthrough

Lpche_advance:
    add x5, x5, #1
    b Lpche_loop

Lpche_end_found:
    add x1, x5, #1 ; skip past the final \n
    ret

Lpche_no_end_found:
    mov x1, #0
    ret

;; same deal. checks for \n instead of \r\n, since cgi is different.
;; input
;; x0 -> header buffer
;; x1 -> length of header
;; x2 -> field to search for
;; x3 -> length of x2
;;
;; return
;; x0 -> pointer to the beginning of the header value
;; x1 -> length in said value
get_cgi_header_field:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]

    mov x19, x0 ; header
    mov x20, x1 ; length
    mov x21, #0 ; index
    mov x22, x2 ; field string
    mov x23, x3 ; field string length

gchf_check:
    add x0, x19, x21
    mov x1, x22
    mov x2, x23
    bl streqn_i
    cbz x0, gchf_scan

    ;; if we're here, it was a match!
    add x21, x21, x23
    ;; but if the header literally ends at "Field:" with nothing following, it's
    ;; malformed as shit
    cmp x21, x20
    b.hs L502 ; tbh i dont even know if this 502 will write to the client lol
    ;; fallthrough
gchf_skip_ws:
    ldrb w2, [x19, x21]
    cmp w2, #' '
    b.eq gchf_skip_ws_next
    cmp w2, #'\t'
    b.eq gchf_skip_ws_next

    ;; once we're here, we've skipped all the whitespace!
    ;; now we've got to find the length of the value
    add x0, x19, x21 ; save pointer to start of value
    mov x1, #0
1:
    ldrb w2, [x0, x1]
    cmp w2, #'\n'
    b.eq 2f
    cmp w2, #'\r'
    b.eq 2f

    add x1, x1, #1
    add x21, x21, #1
    cmp x21, x20
    b.lo 1b
    ;; fallthrough
2:
    ;; now x0 points to start of value,
    ;; x1 is length of value.
    b gchf_epilogue

gchf_skip_ws_next:
    add x21, x21, #1
    cmp x21, x20
    b.hs L502
    b gchf_skip_ws

gchf_scan:
    ;; check your boundaries!
    cmp x21, x20
    b.hs gchf_not_found

    ldrb w2, [x19, x21]
    add x21, x21, #1
    cmp w2, #'\n'
    b.ne gchf_scan

    ;; if we're here, start of a new line. check and the party starts again
    b gchf_check

gchf_not_found:
    cmp xzr, xzr ; set carry
    mov x0, #0
    mov x1, #0
    b 1f

gchf_epilogue:
    cmn xzr, xzr
1:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret

;; input
;; x0 -> header buffer
;; x1 -> header length
;; x2 -> clientfd
;;
;; returns
;; nothing...?
forward_headers_from_script:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]

    mov x19, x0     ; current = start
    add x20, x0, x1 ; end = start + length
    mov x21, x2     ; clientfd

fhfs_next_line:
    ;; bounds check! everybody show me your bounds!
    cmp x19, x20
    b.hs fhfs_done

    mov x22, x19 ; store line start

    ;; if the first byte is a ' ' or '\t', we've got to reject that. it's
    ;; obsolete line folding which is deprecated because of security risks.
    ;; id hope any scripts dont do this, but you never know. reject with 502
    ldrb w3, [x19]
    cmp w3, #' '
    b.eq fhfs_malformed
    cmp w3, #'\t'
    b.eq fhfs_malformed

    ;; look for the end of the line. scan for \n
fhfs_scan:
    ;; if we hit the end of the buffer with no \n, something's broken
    cmp x19, x20
    b.hs fhfs_malformed

    ldrb w3, [x19]
    cmp w3, #'\n'
    b.eq fhfs_found_nl
    add x19, x19, #1
    b fhfs_scan

fhfs_found_nl:
    ;; compute content length
    sub x23, x19, x22
    ;; line length shouldn't possibly be 0, so something mustve gone horribly
    ;; wrong. bail. 
    cbz x23, fhfs_malformed

    ;; strip trailing \r if present
    sub x4, x19, #1
    ldrb w5, [x4]
    cmp w5, #'\r'
    b.ne 1f
    sub x23, x23, #1
1:
    add x19, x19, #1 ; advance past the current \n, for next iteration
    ;; fallthrough
fhfs_check_status:
    ;; check if line starts with "status:"
    ;; oblig bounds check
    mov x2, cgiscr_status_len
    cmp x23, x2           ;>> hii
    b.lo fhfs_check_conn

    mov x0, x22
    adr_l x1, cgiscr_status
    ;; x2 was set up there ^^
    bl streqn_i
    cbnz x0, fhfs_skip_line

fhfs_check_conn:
    ;; check if line starts with "connection:"
    mov x2, cgiscr_conn_len
    cmp x23, x2
    b.lo fhfs_write_line

    mov x0, x22
    adr_l x1, cgiscr_conn
    ;; x2 was already set
    bl streqn_i
    cbnz x0, fhfs_skip_line
    ;; fallthrough
fhfs_write_line:
    ;; write the line + \r\n
    mov x0, x21 ; clientfd
    mov x1, x22 ; line start
    mov x2, x23 ; line length, without the newlines
    bl write_all
    b.cs fhfs_write_error

    mov x0, x21
    adr_l x1, crlf
    mov x2, crlf_len
    bl write_all
    b.cs fhfs_write_error

    b fhfs_next_line

fhfs_skip_line:
    ;; x19 already advanced past the \n, so we can just loop
    b fhfs_next_line

fhfs_done:
    cmn xzr, xzr ; clear carry
    b fhfs_epilogue

fhfs_malformed:
    mov x0, #0 ; set x0 to #0 to differentiate between write failing and
               ; malformed headers.
    ;; fallthrough
fhfs_write_error:
    ;; if we failed due to write, x0 should now be errno.
    cmp xzr, xzr ; set carry
    ;; fallthrough
fhfs_epilogue:
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret


;; read filename_str, and break "/www/cgi-bin/foobar" into "/www/cgi-bin/" in
;; script_path_buf, and "foobar" in script_name_buff. doesnt modify
;; filename_str.
;; input
;; none, reads from globals
;;
;; returns
;; nothing, writes to memory
get_script_path_elements:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]

    ldr_l x19, filename_str
    ldr_l x20, filename_len

    ;; find the index of the last /
    mov x0, x20
1:
    cmp x0, #0
    b.eq Lerror
    ldrb w1, [x19, x0]
    cmp w1, #'/'
    b.eq 2f
    sub x0, x0, #1
    b 1b
2:
    ;; the index of the last slash is now in x0
    ;; add one to it so we dont copy /name_with_slash to script_name_buf, and
    ;; instead copy path/with/slash/ to script_path_buf
    add x0, x0, #1
    ;; if the very last char was a /, it's a directory being requested, and
    ;; that's no good.
    cmp x0, x20
    b.hs Lerror

    mov x3, x0 ; and in x3 lol
    mov x4, #0 ; offset into script_name_buf
    adr_l x1, script_name_buf

    ;; copy from / to the end of string into script_name_buf
1:
    cmp x0, x20
    b.eq 2f
    cmp x4, script_name_buf_len
    b.eq 2f
    ldrb w2, [x19, x0]
    strb w2, [x1, x4]
    add x0, x0, #1
    add x4, x4, #1
    b 1b
2:
    ;; make sure script_name_buf is null terminated
    strb wzr, [x1, x4]

    mov x4, #0
    adr_l x1, script_path_buf
    ;; now we copy from the start of filename_len up to the first /, into
    ;; script_path_buf
1:
    cmp x4, x3
    b.eq 2f
    cmp x4, script_path_buf_len
    b.eq 2f
    ldrb w2, [x19, x4]
    strb w2, [x1, x4]
    add x4, x4, #1
    b 1b
2:
    ;; and make sure script_path_buf is NULL terminated too!
    strb wzr, [x1, x4]

    b Lgspe_epilogue

Lerror:
    mov x27, #0x101
    cmp xzr, xzr ; set carry bit
    b 1f

Lgspe_epilogue:
    cmn xzr, xzr ; clear carry bit
1:
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

Lhfs_error: b handle_fs_error
L403:
    mov x0, #403
    mov x1, #0
    b reply_status
L500:
    mov x0, #500
    mov x1, #0
    b reply_status
L502:
    mov x0, #502
    mov x1, #0
    b reply_status
