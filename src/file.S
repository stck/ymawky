#include "defs.S"

.global get_filetype
.global check_path_safety
.align 4

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
