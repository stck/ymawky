#include "defs.S"

.global itoa
.global strlen
.global memcpy

.align 4

.bss
itoa_buf: .skip 20
.align 3

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
;; x0 -> destination
;; x1 -> source
;; x2 -> length
;; 
;; clobbers x0, x1, and x3
memcpy:
    cbz x2, 1f

    ldrb w3, [x1], #1
    strb w3, [x0], #1

    sub x2, x2, #1
    b memcpy

1:
    ret
