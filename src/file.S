#include "defs.S"

.global get_filetype
.global check_path_traversal
.global check_path_safety
.global decode_url
.align 4

.data
file_types:
    .asciz ".html"
    .skip 2
    .asciz "text/html; charset=utf-8"
    .skip 7

    .asciz ".css"
    .skip 3
    .asciz "text/css; charset=utf-8"
    .skip 8

    .asciz ".js"
    .skip 4
    .asciz "text/javascript; charset=utf-8"
    .skip 1

    .asciz ".json"
    .skip 2
    .asciz "application/json"
    .skip 15

    .asciz ".png"
    .skip 3
    .asciz "image/png"
    .skip 22

    .asciz ".jpg"
    .skip 3
    .asciz "image/jpeg"
    .skip 21

    .asciz ".jpeg"
    .skip 2
    .asciz "image/jpeg"
    .skip 21

    .asciz ".gif"
    .skip 3
    .asciz "image/gif"
    .skip 22

    .asciz ".svg"
    .skip 3
    .asciz "image/svg+xml"
    .skip 18

    .asciz ".ico"
    .skip 3
    .asciz "image/x-icon"
    .skip 19

    .asciz ".webp"
    .skip 2
    .asciz "image/webp"
    .skip 21

    .asciz ".txt"
    .skip 3
    .asciz "text/plain; charset=utf-8"
    .skip 6

    .asciz ".pdf"
    .skip 3
    .asciz "application/pdf"
    .skip 16

    .asciz ".woff2"
    .skip 1
    .asciz "font/woff2"
    .skip 21

    .asciz ".xml"
    .skip 3
    .asciz "text/xml; charset=utf-8"
    .skip 8

    ;; sentinel: empty extension = end of table
    .byte 0

unknown_ct: .ascii "text/plain; charset=utf-8"
.equ unknown_ct_len, . - unknown_ct

.text
;; input
;; x0 -> filename string
;; x1 -> filename length
;;
;; returns
;; x0 -> 1 if safe, 0 if unsafe
;;
;; clobbers
;; x2 -> index into string
;; x3 -> dot count per segment
;; x4 -> segment length
check_path_traversal:
    mov x2, #0
    mov x3, #0
    mov x4, #0

_loop:
    cmp x2, x1
    b.ge _check_segment

    ldrb w5, [x0, x2]

    cmp w5, #'/'
    b.eq _check_segment

    cmp w5, #0
    b.eq _check_segment

    add x2, x2, #1
    add x4, x4, #1

    cmp w5, #'.'
    b.eq 2f

    b _loop

2:
    add x3, x3, #1
    b _loop

_check_segment:
    cmp x3, x4
    b.eq _equal_length

3:
    mov x3, #0
    mov x4, #0

    cmp x2, x1
    b.ge _safe_path

    add x2, x2, #1
    b _loop

_equal_length:
    cmp x3, #2
    b.eq _unsafe_path

    b 3b

_safe_path:
    mov x0, #1
    ret

_unsafe_path:
    mov x0, #0
    ret

;; input
;; x0 -> path to check
;; x1 -> path length
;;
;; returns
;; x0 -> 1 if safe, 0 if unsafe
check_path_safety:
    ;sub x1, x1, #1 ; x1 is the length including the NULL byte. let's get
                   ; rid of that
1:
    ;; if we've reached the end and no issues yet, it's safe
    cbz x1, _safe

    ldrb w3, [x0]

    ;; everything under and including 0x1F, "US" or Unit Separator.
    cmp w3, #0x1F
    b.le _unsafe_path

    ;; everything including and after 0x7F, which is DELETE. everything after
    ;; that is not valid ascii anymore.
    cmp w3, #0x7F
    b.ge _unsafe_path

    sub x1, x1, #1
    add x0, x0, #1
    b 1b

_safe:
    mov x0, #1
    ret

_unsafe:
    mov x0, #0
    ret

;; input
;; x0 -> filename
;; x1 -> filename length
;;
;; returns
;; x0 -> content-type string (eg text/html)
;; x1 -> length of content-type string
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
    mov x6, x1

    adr_l x1, file_types

1:
    ldrb w3, [x1]
    cmp w3, #0
    b.eq _return_unknown

    mov x7, x1 ;; save table pointer
    mov x0, x5 ;; filename, from . and on
    mov x2, #8
    bl strcmp

    cmp x0, #1
    b.eq _match

    add x1, x7, #40
    b 1b

_match:
    add x6, x7, #8
    mov x1, x6 ;; strlen takes x1
    bl strlen  ;; x0 is now length
    mov x1, x0 ;; we want to return length in x1
    mov x0, x6
    b _return


_return_unknown:
    adr_l x0, unknown_ct
    mov x1, unknown_ct_len
    b _return
 
_return:
    ;; restore the link register we pushed to the stack
    ldp x29, x30, [sp], #16
    ret

;; input
;; x0 -> encoded string
;; x1 -> length of encoded string
;;
;; returns
;; x0 -> decoded string (decoded in-place)
;; x1 -> length of decoded string
decode_url:
    stp x29, x30, [sp, #-16]!
    mov x2, x0 ; write pointer
    mov x3, #0 ;; x3 is length of new string

_decode_loop:
    ldrb w4, [x0]
    ;; make sure we're not null
    cmp w4, #0
    b.eq _decode_end

    cmp w4, #'%'
    b.eq _encoded_char

    strb w4, [x2, x3]
    add x3, x3, #1

    ;; make sure we're not reading beyond the length of the string
    sub x1, x1, #1
    cmp x1, #0
    b.eq _decode_end

    add x0, x0, #1 ; increment along the new string to the next char
    b _decode_loop

_encoded_char:
    cmp x1, #3
    b.lt _bad_end

    ;; high nibble
    ldrb w4, [x0, #1]
    bl _hex_to_val
    lsl w5, w4, #4 ; stash in w5

    ;; low nibble
    ldrb w4, [x0, #2]
    bl _hex_to_val
    orr w4, w5, w4 ; combine w5 (high nibble) with w4 (low nibble)

    cmp w4, #0
    b.le _bad_end

    ;; now w4 contains the decoded byte
    strb w4, [x2, x3]

    sub x1, x1, #3
    cmp x1, #0
    b.le _decode_end

    add x3, x3, #1
    add x0, x0, #3
    b _decode_loop

_hex_to_val:
    orr w4, w4, #0x20

    cmp w4, #'0'
    b.lt _bad_end
    cmp w4, #'9'
    b.le 1f

    cmp w4, #'a'
    b.lt _bad_end
    cmp w4, #'f'
    b.gt _bad_end

    sub w4, w4, #'a' - 10
    ret
1:
    sub w4, w4, #'0'
    ret

_decode_end:
    ldp x29, x30, [sp], #16
    mov x0, x2
    mov x1, x3

    strb wzr, [x0, x1] ;; null terminate decoded string
    ret

_bad_end:
    ldp x29, x30, [sp], #16
    mov x0, #0
    mov x1, #0
    ret
