;; file.S
;; filesystem ops: stat, path safety / traversal checks, URL decoding,
;; file extension -> MIME type lookup.

#include "defs.S"

.macro mime_entry ext, mime
99:
    .asciz "\ext"
    .space 8 - (. - 99b)  ;; pad to offset 8 from entry start
    .asciz "\mime"
    .space 40 - (. - 99b) ;; pad to offset 40 from entry start
.endm

.global stat_fd
.global stat_path
.global get_filetype
.global check_path_traversal
.global check_path_safety
.global decode_url

.data
;; table of file extension / corresponding MIME types.
;; this table is offset by 40 bytes per entry; 8 bytes for the extension, and
;; 32 bytes for the MIME type string.
file_types:
    ;; web stuff
    mime_entry ".html",  "text/html; charset=utf-8"
    mime_entry ".css",   "text/css; charset=utf-8"
    mime_entry ".xml",   "text/xml; charset=utf-8"
    mime_entry ".js",    "text/javascript; charset=utf-8"
    mime_entry ".json",  "application/json"
    mime_entry ".wasm",  "application/wasm"
    mime_entry ".mfs",   "text/javascript; charset=utf-8"
    mime_entry ".map",   "application/json"

    ;; image
    mime_entry ".png",   "image/png"
    mime_entry ".jpg",   "image/jpeg"
    mime_entry ".jpeg",  "image/jpeg"
    mime_entry ".gif",   "image/gif"
    mime_entry ".svg",   "image/svg+xml"
    mime_entry ".ico",   "image/x-icon"
    mime_entry ".webp",  "image/webp"
    mime_entry ".avif",  "image/avif"

    ;; fonts
    mime_entry ".woff",  "font/woff"
    mime_entry ".woff2", "font/woff2"
    mime_entry ".ttf",   "font/ttf"
    mime_entry ".otf",   "font/otf"

    ;; misc files
    mime_entry ".txt",   "text/plain; charset=utf-8"
    mime_entry ".pdf",   "application/pdf"

    ;; video
    mime_entry ".mp4",   "video/mp4"
    mime_entry ".webm",  "video/webm"

    ;; audio
    mime_entry ".mp3",   "audio/mpeg"
    mime_entry ".ogg",   "audio/ogg"
    mime_entry ".wav",   "audio/wav"

    ;; archives
    mime_entry ".zip",   "application/zip"
    mime_entry ".gz",    "application/gzip"
    mime_entry ".tar",   "application/x-tar"

    ;; empty extension = end of table
    .byte 0

unknown_ct: .ascii "text/plain; charset=utf-8"
.equ unknown_ct_len, . - unknown_ct

.text
.align 2

;; run fstat64() on file descirptor, returning file size and type
;; input
;; x0 -> file descriptor
;;
;; returns
;; x0 -> 0 on success, otherwise, errno from stat64
;; x1 -> file type
;; x2 -> size
stat_fd:
    sub sp, sp, #160 ; reserve stack buffer (stat requires 144 bytes, round up)
    mov x16, SYS_fstat64
    ;; x0 is already set
    mov x1, sp ; stat buffer, on the stack
    svc #0x80
    b.cs Lstat_fd_failed

    ; read st_mode (halfword at offset 4 in stat buffer)
    ; NOTE st_mode in struct stat64 is a mode_t (u16) inside the stat struct,
    ; NOTE at offset 4. if that ever changes, look here!
    ldrh w1, [sp, #4]
    and w1, w1, #0xF000 ; mask S_IFMT
    ldr x2, [sp, #96] ; load st_size into x2
    mov x0, #0
    b Lstat_fd_end

Lstat_fd_failed:
    ;; x0 is already errno. these two movs aren't strictly necessary, but i
    ;; think it's nice to have it all zeroed out.
    mov x1, #0
    mov x2, #0
    ; NOTE fallthrough to Lstat_end

Lstat_fd_end:
    add sp, sp, #160
    ret


;; run stat64() on file path, returning file size and type
;; input
;; x0 -> file path
;;
;; returns
;; x0 -> 0 on success, otherwise, errno from stat64
;; x1 -> file type
;; x2 -> size
stat_path:
    sub sp, sp, #160 ; reserve stack buffer (stat requires 144 bytes, round up)
    mov x16, SYS_stat64
    ;; x0 is already set
    mov x1, sp ; stat buffer, on the stack
    svc #0x80
    b.cs Lstat_path_failed

    ; read st_mode (halfword at offset 4 in stat buffer)
    ; NOTE st_mode in struct stat64 is a mode_t (u16) inside the stat struct,
    ; NOTE at offset 4. if that ever changes, look here!
    ldrh w1, [sp, #4]
    and w1, w1, #0xF000 ; mask S_IFMT
    ldr x2, [sp, #96] ; load st_size into x2
    mov x0, #0
    b Lstat_path_end

Lstat_path_failed:
    ;; x0 is already errno. these two movs aren't strictly necessary, but i
    ;; think it's nice to have it all zeroed out.
    mov x1, #0
    mov x2, #0
    ; NOTE fallthrough to Lstat_end

Lstat_path_end:
    add sp, sp, #160
    ret


;; checks for path traversal: GET /../../file.txt
;; it does not do anything else. one "." is fine. more than two "..." is fine.
;; two ".." in a file "foo..txt" is fine. but a path segment being just .. is
;; no good!
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

Lloop:
    cmp x2, x1
    b.ge Lcheck_segment

    ldrb w5, [x0, x2]

    cmp w5, #'/'
    b.eq Lcheck_segment

    cmp w5, #0
    b.eq Lcheck_segment

    add x2, x2, #1
    add x4, x4, #1

    cmp w5, #'.'
    b.eq 2f

    b Lloop

2:
    add x3, x3, #1
    b Lloop

Lcheck_segment:
    cmp x3, x4
    b.eq Lequal_length

3:
    mov x3, #0
    mov x4, #0

    cmp x2, x1
    b.ge Lno_path_traversal

    add x2, x2, #1
    b Lloop

Lequal_length:
    cmp x3, #2
    b.eq Lpath_traversal

    b 3b

Lno_path_traversal:
    mov x0, #1
    ret

Lpath_traversal:
    mov x0, #0
    ret


;; ensure a path only has ascii characters.
;; input
;; x0 -> path to check
;; x1 -> path length
;;
;; returns
;; x0 -> 1 if safe, 0 if unsafe
check_path_safety:
    ;; if we've reached the end and no issues yet, it's safe
    cbz x1, Lsafe

    ldrb w3, [x0]

    ;; everything under and including 0x1F, "US" or Unit Separator.
    cmp w3, #0x1F
    b.le Lunsafe

    ;; everything including and after 0x7F, which is DELETE. everything after
    ;; that is not valid ascii anymore.
    cmp w3, #0x7F
    b.ge Lunsafe

    sub x1, x1, #1
    add x0, x0, #1
    b check_path_safety

Lsafe:
    mov x0, #1
    ret

Lunsafe:
    mov x0, #0
    ret


;; given a filename, extract the extension and return MIME type.
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
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    str x23, [sp, #48]
    mov x19, x0 ; save the start pointer
    add x0, x0, x1 ; now x0 points to one past the end of the string

1:
    ; are we at the start again? if so, no file extension was present.
    cmp x0, x19
    b.eq Lreturn_unknown

    sub x0, x0, #1

    ldrb w20, [x0]
    cmp w20, #'.'
    b.eq Lfound_extension

    b 1b

;; Ok, now x0 is pointing at the '.' in the filename
Lfound_extension:
    mov x21, x0 ;; save this position
    mov x22, x1

    adr_l x1, file_types

1:
    ldrb w20, [x1]
    cmp w20, #0
    b.eq Lreturn_unknown

    mov x23, x1 ;; save table pointer
    mov x0, x21 ;; filename, from . and on
    mov x2, #8
    bl streqn_i

    cmp x0, #1
    b.eq Lmatch

    add x1, x23, #40
    b 1b

Lmatch:
    add x22, x23, #8
    mov x1, x22 ;; strlen takes x1
    bl strlen  ;; x0 is now length
    mov x1, x0 ;; we want to return length in x1
    mov x0, x22
    b Lreturn

Lreturn_unknown:
    adr_l x0, unknown_ct
    mov x1, unknown_ct_len
    b Lreturn
 
Lreturn:
    ;; restore the link register we pushed to the stack
    ldr x23, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret


;; convert %XX in URL to 0xXX raw bytes. %0a = newline, %20 = space, etc.
;; input
;; x0 -> encoded string
;; x1 -> length of encoded string
;;
;; returns
;; x0 -> decoded string (decoded in-place)
;; x1 -> length of decoded string
decode_url:
    stp x29, x30, [sp, #-32]!
    str x20, [sp, #16]
    mov x2, x0 ; write pointer
    mov x3, #0 ;; x3 is length of new string

Ldecode_loop:
    ldrb w4, [x0]
    ;; make sure we're not null
    cmp w4, #0
    b.eq Ldecode_end

    cmp w4, #'%'
    b.eq Lencoded_char

    strb w4, [x2, x3]
    add x3, x3, #1

    ;; make sure we're not reading beyond the length of the string
    sub x1, x1, #1
    cmp x1, #0
    b.eq Ldecode_end

    add x0, x0, #1 ; increment along the new string to the next char
    b Ldecode_loop

Lencoded_char:
    cmp x1, #3
    b.lt Lbad_end

    ;; high nibble
    ldrb w4, [x0, #1]
    bl hex_to_val
    cbnz x20, Lbad_end

    lsl w5, w4, #4 ; stash in w5

    ;; low nibble
    ldrb w4, [x0, #2]
    bl hex_to_val
    cbnz x20, Lbad_end

    orr w4, w5, w4 ; combine w5 (high nibble) with w4 (low nibble)

    cmp w4, #0
    b.eq Lbad_end

    ;; now w4 contains the decoded byte
    strb w4, [x2, x3]

    add x3, x3, #1
    sub x1, x1, #3
    cmp x1, #0
    b.le Ldecode_end

    add x0, x0, #3
    b Ldecode_loop

hex_to_val:
    orr w4, w4, #0x20

    cmp w4, #'0'
    b.lt 2f
    cmp w4, #'9'
    b.le 1f

    cmp w4, #'a'
    b.lt 2f
    cmp w4, #'f'
    b.gt 2f

    mov x20, #0
    sub w4, w4, #'a' - 10
    ret
1:
    mov x20, #0
    sub w4, w4, #'0'
    ret
2:
    mov x20, #1
    ret

Ldecode_end:
    mov x0, x2
    mov x1, x3

    strb wzr, [x0, x1] ;; null terminate decoded string
    b Ldecode_epilogue

Lbad_end:
    mov x0, #0
    mov x1, #0
    b Ldecode_epilogue

Ldecode_epilogue:
    ldr x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
