#include "defs.S"

.global parse_path
.global parse_header_end
.global streqn
.align 4

;; this is PATH_MAX
.equ filename_buf_size, 4096

.data
header_end: .ascii "\r\n\r\n"
.equ header_end_len, . - header_end

www_prefix: .ascii "www/"
.equ www_prefix_len, . - www_prefix

default_file: .ascii "index.html"
.equ default_file_len, . - default_file

.bss
;; probably way too defensive, but can't hurt, eh?
filename_buf: .skip filename_buf_size + 1
.align 3 ;; fix broken alignment again

.text
;; input
;; x0 -> HTTP header from client ("GET /...")
;; 
;; return
;; x0 -> string containing requested file name
;; x1 -> length of said file name
;;
;; clobbers x0, x1, x2, x3
parse_path:
    ;; preserve link register so we can bl to other functions properly
    stp x29, x30, [sp, #-16]!
    mov x1, #0
    mov x2, #1 ;; just has to be non-null, previous byte to make sure a space
               ;; precedes the '/'
;; this is basically strchr
Lstrchr_loop:
    ;; load the current byte at the string pointer, and check if it's /
    ldrb w3, [x0]
    cmp w3, #'/'
    b.eq Lchar_found

    ;; if we haven't reached a / in the first 16 bytes, we'll fail
    cmp x1, #16
    b.eq Lno_match

    ;; if we reached a NULL byte in the first 16 bytes, it's definitely a
    ;; weird request header. so, let's just fail.
    cmp w3, #0
    b.eq Lno_match

    ;; if we got here, we gotta loop again. < 16 bytes in, no / reached, and no
    ;; NULL byte reached. increment string index and loop
    add x0, x0, #1 ;; increment the string pointer
    add x1, x1, #1 ;; increment the byte counter so we can quit at 16 bytes
    
    ;; save previous byte so we can check for preceding ' '
    mov w2, w3
    b Lstrchr_loop

;; If we got here, we found a '/'. let's make sure the preceding byte -- stored
;; in x2, is a ' ' so we only match ' /'. that way we avoid 'HTTP/1.1'
;; "matching".
Lchar_found:
    cmp w2, #' '
    b.ne Lno_match

    add x0, x0, #1 ;; skip past the '/' which we're currently on

    ;; zero out x2, which is used as both an index into filename_buf and as a
    ;; relative index (x2 + 4, to skip the starting "GET ") into the header
    mov x2, #0

    ;; load in filename_buf to x1
    adr_l x1, filename_buf

    mov x8, x3
    mov x7, x2
    mov x6, x1
    mov x5, x0

    mov x0, x6
    adr_l x1, www_prefix
    mov x2, www_prefix_len
    bl memcpy

    mov x0, x5
    mov x1, x6
    mov x2, x7
    mov x3, x8
    mov x4, www_prefix_len

Lfilename_loop:
    cmp x4, filename_buf_size ; bounds check
    b.ge Lno_match

    ldrb w3, [x0, x2] ; load byte from header+index
    cbz w3, Lno_match ; is it NULL? go to 4f if it is

    cmp w3, #' ' ; is it a space?
    b.eq Lfilename_done ; we're done once we reach a space

    cmp w3, #'\r'
    b.eq Lno_match

    cmp w3, #'\n'
    b.eq Lno_match

    ;; ok, we're not done
    strb w3, [x1, x4] ; copy byte to filename_buf+index
    add x4, x4, #1 ; increment the filename index
    add x2, x2, #1 ; increment the header index
    b Lfilename_loop

Lfilename_done:
    ;; is the length the same as the www/ prefix? if it is, we didn't actually
    ;; get a file.
    mov x5, www_prefix_len
    cmp x4, x5
    b.eq Lempty_filename

    strb wzr, [x1, x4] ;; null-terminate filename_buf
    mov x0, x1 ; we want x0 to point to the filename string
    mov x1, x4 ; x1 is the length of the filename
    b Lparse_return

Lempty_filename:
    mov x5, x1 ; save filename_buf in x5
    mov x2, www_prefix_len

    ; the default file name, "index.html", is only for GET requests. if it's a
    ; DELETE/PUT/POST/anything else, just "www/" is enough. we'll let the
    ; system handle the error elsewhere if it causes problems.
    cmp x20, GET_REQ_ID
    b.ne Lnot_get

    adr_l x0, filename_buf
    ;; skip past the www/
    add x0, x0, x2

    adr_l x1, default_file
    mov x2, default_file_len
    bl memcpy

    strb wzr, [x0] ;; null terminate

    mov x0, x5
    mov x1, www_prefix_len
    mov x2, default_file_len
    add x1, x1, x2

    b Lparse_return
Lnot_get:
    mov x0, x5
    mov x1, www_prefix_len
    b Lparse_return

;; no match was when we were parsing the header for request type. since we cant
;; find a file without a /, just return NULL
Lno_match:
    mov x0, #0
    mov x1, #0
    b Lparse_return

Lparse_return:
    ;; restore the link register and ret
    ldp x29, x30, [sp], #16
    ret

;; input
;; x0 -> string
;; x1 -> length
;;
;; return
;; x1 -> index of the first byte after the header
parse_header_end:
    adr_l x2, header_end
    mov x5, #0
    mov x6, #0
Lheader_end_loop:
    cmp x5, x1
    b.ge Lno_end_found

    ldrb w3, [x0, x5]
    ldrb w4, [x2, x6]

    cmp w3, w4
    b.eq Lcorrect_char

    b Lincorrect_char

Lcorrect_char:
    add x6, x6, #1

    cmp x6, #4 ; length of \r\n\r\n
    b.ge Lend_found

    add x5, x5, #1
    b Lheader_end_loop

Lincorrect_char:
    mov x6, #0
    cmp w3, #'\r' ; this \r starts a new potential match, eg, \r\n\r>\r<\n\r\n
    b.ne 2f
    mov x6, #1
2:
    add x5, x5, #1
    b Lheader_end_loop

Lend_found:
    add x1, x5, #1
    ret

Lno_end_found:
    mov x1, #0
    ret


;; input
;; x0 -> str1
;; x1 -> str2
;; x2 -> max length
;;
;; returns
;; x0 -> 1 if match, 0 if doesn't match
streqn:
    ldrb w3, [x0]
    ldrb w4, [x1]
    cmp w3, w4
    b.ne Lstreqn_no_match

    cbz w3, Lstreqn_match ;; both equal and both NULL = end of string = match

    ;; if we've reached the end, it's a match yeah?
    subs x2, x2, #1
    b.eq Lstreqn_match

    add x0, x0, #1
    add x1, x1, #1
    b streqn

Lstreqn_match:
    mov x0, #1
    ret

Lstreqn_no_match:
    mov x0, #0
    ret
