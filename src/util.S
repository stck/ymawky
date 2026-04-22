#include "defs.S"

.global itoa
.global atoi
.global strlen
.global memcpy

.align 4

.bss
itoa_buf: .skip 20
.align 3

.text

;; convert integer into non-NULL-terminated string.
;; input
;; x0 -> number to convert
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

;; convert NULL-terminated string to integer
;; input
;; x0 -> pointer to string
;;
;; returns
;; x0 -> integer representation of string
atoi:
    mov x1, #0
    mov x3, #10
1:
    ldrb w2, [x0]
    cbz w2, 2f

    ; make sure we actually have a number
    cmp w2, #'0'
    b.lo Latoi_error
    cmp w2, #'9'
    b.hi Latoi_error

    mul x1, x1, x3
    sub w2, w2, #'0'
    add x1, x1, x2
    add x0, x0, #1
    b 1b
2:
    mov x0, x1
    ret

Latoi_error:
    mrs x4, NZCV
    orr x4, x4, #0x20000000 ; set carry bit
    msr NZCV, x4
    mov x0, #0
    ret

;; convert string representation of number into an integer. read up to N bytes
;; from string, does not need to be NULL terminated.
;; input
;; x0 -> pointer to string
;; x1 -> length of string
;;
;; returns
;; x0 -> integer representation of string
atoi_n:
    mov x2, #0
    mov x4, #10
2:
    cbz x1, 3f

    ldrb w3, [x0]

    ; make sure we actually have a number
    cmp w3, #'0'
    b.lo Latoi_n_error
    cmp w3, #'9'
    b.hi Latoi_n_error

    mul x2, x2, x4
    sub w3, w3, #'0'
    add x2, x2, x3
    add x0, x0, #1

    sub x1, x1, #1
    b 2b
3:
    mov x0, x2
    ret

Latoi_n_error:
    mrs x5, NZCV
    orr x5, x5, #0x20000000 ; set carry bit
    msr NZCV, x5
    mov x0, #0
    ret

;; copies N bytes from x1 into x0
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

;; gets the length of a NULL-terminated string.
;; input
;; x1 -> string whose length to check
;;
;; return
;; x0 -> length of string
strlen:
    mov x0, #0
1:
    ldrb w3, [x1, x0]
    cbz w3, 2f
    add x0, x0, #1
    b 1b

2:
    ret
