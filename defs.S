;; defs.S

;; macros
;; turn adrp ... add ... into one call, adrl_l
.macro adr_l, reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

;; same with adrp ... (add ...) ldr ...
.macro ldr_l reg, sym
    adrp \reg, \sym@PAGE
    ldr \reg, [\reg, \sym@PAGEOFF]
.endm

;; and adrp ... (add ...) str ...
.macro str_l src, sym, scratch=x9
    adrp \scratch, \sym@PAGE
    str \src, [\scratch, \sym@PAGEOFF]
.endm

;; syscalls
.equ SYS_exit, 1
.equ SYS_read, 3
.equ SYS_write, 4
.equ SYS_open, 5
.equ SYS_close, 6
.equ SYS_accept, 30
.equ SYS_socket, 97
.equ SYS_bind, 104
.equ SYS_setsockopt, 105
.equ SYS_listen, 106
.equ SYS_shutdown, 134

;; constants
.equ BUF_SIZE, 16384
.equ FILE_SIZE_MAX, 65536

