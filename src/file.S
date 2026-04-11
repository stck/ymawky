#include "defs.S"

.global read_file
.global get_filetype
.global check_path_safety
.align 4

.bss
file_buf: .skip FILE_SIZE_MAX ; 64KB max HTML file :/

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
    ;; did read set the carry flag, indicating an error?
    ;; we gotta close the file first, so jump to 2f, which closes the file
    ;; then jumps to ret.
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
    ;; If we got here, it's because read set the carry flag. We don't want
    ;; close to overwrite it, so let's stash it first
    mrs x5, NZCV

    ;; close(filedes)
    mov x16, SYS_close
    mov x0, x4
    svc #0x80

    ;; now re restore the carry flag set from read()
    msr NZCV, x5
    b 1b

;; input
;; x0 -> filename string
;; x1 -> filename length
;;
;; returns
;; x0 -> 1 if safe, 0 if unsafe
check_path_safety:
    mov x2, #0

1:
    ;; if we're at the end of the string and there's no match yet, finish up
    cmp x2, x1
    b.ge _safe_path

    ldrb w3, [x0]
    ldrb w4, [x0, #1]

    ;; check if x0 and x0+1 are both .
    cmp w3, #'.'
    b.ne _loop_again

    cmp w4, #'.'
    b.ne _loop_again

    ;; if we got here, both bytes were '.'
    b _unsafe_path

_loop_again:
    add x2, x2, #1
    add x0, x0, #1
    b 1b

_unsafe_path:
    mov x0, #0
    ret

_safe_path:
    mov x0, #1
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
    mov x0, x5
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
