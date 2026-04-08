.global _itoa
.global _strlen
.global _read_file
.align 4

.equ SYS_open, 5
.equ SYS_read, 3
.equ SYS_close, 6

.equ FILE_SIZE_MAX, 65536

.bss
file_buf: .skip FILE_SIZE_MAX ; 64KB max HTML file :/
itoa_buf: .skip 20

.data
filename: .asciz "./index.html"

.text
;; input
;; xq0 -> number to convert
;;
;; returns
;; x0 -> pointer to start of string
;; x1 -> length of string
;;
;; clobbers x0, x1, x2, x3, x4, x5
_itoa:
    adrp x1, itoa_buf@PAGE
    add x1, x1, itoa_buf@PAGEOFF
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
_strlen:
    eor x0, x0, x0
1:
    ldrb w3, [x1, x0] ; w3 = x1[x0]
    cbz w3, 2f ; jump to 2 if w3 is 0. end of string
    add x0, x0, #1
    b 1b
2:
    ret

;; input
;; none?
;;
;; return
;; x0 -> pointer to file content string
;; x1 -> bytes read
;;
;; clobbers: x0-2, x18, x19
_read_file:
    ;; open(filename, O_RDONLY);
    mov x16, SYS_open
    adrp x0, filename@PAGE
    add x0, x0, filename@PAGEOFF
    mov x1, #0
    svc #0x80
    mov x19, x0 ; save filedes in x19

    ;; read(filedes, file_buf, FILE_SIZE_MAX)
    mov x16, SYS_read
    adrp x1, file_buf@PAGE
    add x1, x1, file_buf@PAGEOFF
    mov x2, FILE_SIZE_MAX
    svc #0x80
    mov x18, x0 ; save bytes read in x18

    ;; close(filedes)
    mov x16, SYS_close
    mov x0, x19
    svc #0x80

    adrp x0, file_buf@PAGE
    add x0, x0, file_buf@PAGEOFF ; x0 -> pointer to file contents
    mov x1, x18 ; x18 -> number of bytes read
    ret
