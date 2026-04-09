#include "defs.S"

.global itoa
.global strlen
.global read_file
.global parse_path
.global get_filetype
.align 4

.bss
file_buf: .skip FILE_SIZE_MAX ; 64KB max HTML file :/
itoa_buf: .skip 20
filename_buf: .skip 4096 ;; probably way too defensive, but can't hurt, eh?

.data
html_ext: .asciz ".html"
.equ html_ext_len, . - html_ext

js_ext: .asciz ".js"
.equ js_ext_len, . - js_ext

css_ext: .asciz ".css"
.equ css_ext_len, . - css_ext

html_ct: .ascii "text/html"
.equ html_ct_len, . - html_ct

css_ct: .ascii "text/css"
.equ css_ct_len, . - css_ct

js_ct: .ascii "text/javascript"
.equ js_ct_len, . - js_ct

unknown_ct: .ascii "text/plain"
.equ unknown_ct_len, . - unknown_ct

.text
;; input
;; xq0 -> number to convert
;;
;; returns
;; x0 -> pointer to start of string
;; x1 -> length of string
;;
;; clobbers x0, x1, x2, x3, x4, x5
itoa:
    adr_l x1, itoa_buf
    add x1, x1, #20 ; Start at the END of the buffer and write backwards
    mov x2, #0      ; length counter
    mov x3, #10     ; divisor
1:
    udiv x4, x0, x3     ; x4 = x0 / 10
    msub x5, x4, x3, x0 ; x5 = x0 - (x4 * x10) = remainder
    add x5, x5, #'0'    ; converts to ascii
    sub x1, x1, #1      ; move pointer back
    strb w5, [x1]       ; stores the digit
    add x2, x2, #1      ; length++
    mov x0, x4          ; quotient becomes new number
    cbnz x0, 1b         ; jump back to 1 if not 0

    mov x0, x1 ; x0 = pointer to start
    mov x1, x2 ; x1 = length
    ret

;; input
;; x1 -> pointer to string (must be NULL terminated)
;; 
;; returns
;; x0 -> length of string
;;
;; clobbers x0, x1, and x3
strlen:
    mov x0, #0
1:
    ldrb w3, [x1, x0] ; w3 = x1[x0]
    cbz w3, 2f ; jump to 2 if w3 is 0. end of string
    add x0, x0, #1
    b 1b
2:
    ret

;; input
;; x0 -> str1
;; x1 -> str2
;; x2 -> max length
;;
;; returns
;; x0 -> 1 if match, 0 if doesn't match
strcmp:
    ldrb w3, [x0]
    ldrb w4, [x1]
    cmp w3, w4
    b.ne _no_match

    ;; if we've reached the end, it's a match yeah?
    subs x2, x2, #1
    b.eq _match

    add x0, x0, #1
    add x1, x1, #1
    b strcmp

_match:
    mov x0, #1
    ret

_no_match:
    mov x0, #0
    ret

;; input
;; x0 -> filename to open
;;
;; return
;; x0 -> pointer to file content string
;; x1 -> bytes read
;;
;; clobbers x0-2, x3, x4
read_file:
    ;; open(filename, O_RDONLY);
    mov x16, SYS_open
    ;; x0 should already be index.html
    mov x1, #0
    svc #0x80
    ;; did open return -1? just ret immediately
    ;; apparently the carry flag will be set instead of x0 being -1
    b.cs 1f
    mov x4, x0 ; save filedes in x4

    ;; read(filedes, file_buf, FILE_SIZE_MAX)
    mov x16, SYS_read
    ; x0 should be filedes still from open() returning it
    adr_l x1, file_buf
    mov x2, FILE_SIZE_MAX
    svc #0x80
    ;; did read return -1? we gotta close the file first, so jump to 2f,
    ;; which closes the file then jumps to ret.
    b.cs 2f
    mov x3, x0 ; save bytes read in x3

    ;; close(filedes)
    mov x16, SYS_close
    mov x0, x4
    svc #0x80

    adr_l x0, file_buf ; x0 -> pointer to file contents
    mov x1, x3 ; x3 -> number of bytes read

1:
    ret

2:
    ;; close(filedes)
    mov x16, SYS_close
    mov x0, x4
    svc #0x80
    b 1b


;; input
;; x0 -> HTTP header from client ("GET /...")
;; 
;; return
;; x0 -> string containing requested file name
;; x1 -> length of said file name
;;
;; clobbers x0, x1, x2, x3
parse_path:
    ;; skip "GET /" in the header, now x0 points at the start of the path
    add x0, x0, #5

    ;; zero out x2, which is used as both an index into filename_buf and as a
    ;; relative index (x2 + 4, to skip the starting "GET ") into the header
    mov x2, #0

    ;; load in filename_buf to x1
    adr_l x1, filename_buf

1:
    ldrb w3, [x0, x2] ; load byte from header+index
    cmp w3, #' ' ; is it a space?
    b.eq 2f ; we're done once we reach a space

    ;; ok, we're not done
    strb w3, [x1, x2] ; copy bytee to filename_buf+index

    add x2, x2, #1 ; increment the index
    b 1b ; and loop

2:
    strb wzr, [x1, x2] ;; null-terminate filename_buf
    mov x0, x1 ; we want x0 to point to the filename string
    mov x1, x2 ; x1 is the length of the filename
    ret

;; input
;; x0 -> filename
;; x1 -> filename length
;;
;; returns
;; x0 -> content-type string (eg text/html)
;; x1 -> length of content-type string
;; x2 -> filetype const from defs.S, eg, FILETYPE_HTML (1).
get_filetype:
    ;; push the link register to the stack sorta. since we bl strcmp, we need
    ;; to preserve it
    stp x29, x30, [sp, #-16]!
    mov x4, x0 ; save the start pointer
    add x0, x0, x1 ; now x0 points to one past the end of the string

1:
    sub x0, x0, #1
    ldrb w3, [x0]
    cmp w3, #'.'
    b.eq _found_extension

    ; are we at the start again? if so, no file extension was present.
    cmp x0, x4
    b.eq _return_unknown

    b 1b

;; Ok, now x0 is pointing at the '.' in the filename
_found_extension:
    mov x5, x0 ;; save this position

1:
    ;; is it .html?
    adr_l x1, html_ext
    mov x2, html_ext_len
    bl strcmp
    cbnz x0, _return_html

    ;; nope. how about .css?
    mov x0, x5
    adr_l x1, css_ext
    mov x2, css_ext_len
    bl strcmp
    cbnz x0, _return_css

    ;; nope. how about .js?
    mov x0, x1
    adr_l x1, js_ext
    mov x2, js_ext_len
    bl strcmp
    cbnz x0, _return_js

    ;; none of em. unknown file extension
    b _return_unknown


_return_html:
    adr_l x0, html_ct
    mov x1, html_ct_len
    mov x2, FILETYPE_HTML
    b _return

_return_css:
    adr_l x0, css_ct
    mov x1, css_ct_len
    mov x2, FILETYPE_CSS
    b _return

_return_js:
    adr_l x0, js_ct
    mov x1, js_ct_len
    mov x2, FILETYPE_JS
    b _return

_return_unknown:
    adr_l x0, unknown_ct
    mov x1, unknown_ct_len
    mov x2, FILETYPE_UNKNOWN
    b _return

_return:
    ;; restore the link register we pushed to the stack
    ldp x29, x30, [sp], #16
    ret
