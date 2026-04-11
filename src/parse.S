#include "defs.S"

.global parse_path
.global strcmp
.align 4

;; this is PATH_MAX
.equ filename_buf_size, 4096

.bss
;; probably way too defensive, but can't hurt, eh?
filename_buf: .skip filename_buf_size + 1

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
    mov x1, #0
    mov x2, #1 ;; just has to be non-null, previous byte to make sure a space
               ;; precedes the '/'
;; this is basically strchr
1:
    ;; load the current byte at the string pointer, and check if it's /
    ldrb w3, [x0]
    cmp w3, #'/'
    b.eq 1f
    ;b.eq 1f

    ;; if we haven't reached a / in the first 16 bytes, we'll fail
    cmp x1, #16
    b.eq 4f

    ;; if we reached a NULL byte in the first 16 bytes, it's definitely a
    ;; weird request header. so, let's just fail.
    cmp w3, #0
    b.eq 4f

    ;; if we got here, we gotta loop again. < 16 bytes in, no / reached, and no
    ;; NULL byte reached. increment string index and loop
    add x0, x0, #1 ;; increment the string pointer
    add x1, x1, #1 ;; increment the byte counter so we can quit at 16 bytes
    
    ;; save previous byte so we can check for preceding ' '
    mov w2, w3
    b 1b

;; If we got here, we found a '/'. let's make sure the preceding byte -- stored
;; in x2, is a ' ' so we only match ' /'. that way we avoid 'HTTP/1.1'
;; "matching".
1:
    cmp w2, #' '
    b.ne 4f

    add x0, x0, #1 ;; skip past the '/' which we're currently on

    ;; zero out x2, which is used as both an index into filename_buf and as a
    ;; relative index (x2 + 4, to skip the starting "GET ") into the header
    mov x2, #0

    ;; load in filename_buf to x1
    adr_l x1, filename_buf

2:
    cmp x2, filename_buf_size ; bounds check
    b.ge 4f

    ldrb w3, [x0, x2] ; load byte from header+index
    cbz w3, 4f ; is it NULL? go to 4f if it is

    cmp w3, #' ' ; is it a space?
    b.eq 3f ; we're done once we reach a space

    cmp w3, #'\r'
    b.eq 4f

    cmp w3, #'\n'
    b.eq 4f

    ;; ok, we're not done
    strb w3, [x1, x2] ; copy byte to filename_buf+index
    add x2, x2, #1 ; increment the index
    b 2b ; and loop

3:
    strb wzr, [x1, x2] ;; null-terminate filename_buf
    mov x0, x1 ; we want x0 to point to the filename string
    mov x1, x2 ; x1 is the length of the filename
    ret

;; no match was when we were parsing the header for request type. since we cant
;; find a file without a /, just return NULL
4:
    mov x0, #0
    mov x1, #0
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
