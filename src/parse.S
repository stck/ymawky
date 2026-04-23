#include "defs.S"

.global parse_path
.global parse_header_end
.global parse_content_length
.global streqn
.align 4

;; this is PATH_MAX
.equ filename_buf_size, 4096
.equ MAX_BODY_SIZE, 1024 * 1024 * 1024

.data
header_end: .ascii "\r\n\r\n"
.equ header_end_len, . - header_end

content_len_match_str: .ascii "content-length"
.equ content_len_match_len, 14

www_prefix: .ascii "www/"
.equ www_prefix_len, . - www_prefix

default_file: .ascii "index.html"
.equ default_file_len, . - default_file

.bss
;; probably way too defensive, but can't hurt, eh?
filename_buf: .skip filename_buf_size + 1
.align 3 ;; fix broken alignment again

.text
;; input
;; x0 -> HTTP header from client
;; x1 -> length of header
;;
;; return
;; x0 -> content length as an integer
parse_content_length:
    stp x29, x30, [sp, #-48]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]

    mov x19, x0  ; headers
    mov x20, x1  ; length
    mov x21, #0  ; index
    mov x22, #-1 ; value, sentinel -1 = not found yet

pcl_scan:
    cmp x21, x20
    b.ge pcl_done

    ldrb w2, [x19, x21]
    cmp w2, #'\r'
    b.ne Lscan_again

    add x21, x21, #1
    cmp x21, x20
    b.ge pcl_done

    ldrb w2, [x19, x21]
    cmp w2, #'\n'
    b.ne pcl_scan ; x21 already advanced. lone \r, so keep scanning.

    ;; we're at \r\n, next line begins at x21+1
    add x21, x21, #1
    cmp x21, x20
    b.ge pcl_done

    ldrb w2, [x19, x21]
    cmp w2, #' '
    b.eq L400
    cmp w2, #'\t'
    b.eq L400

    ;; if (length - index) < strlen("content-length:"), end of header is too
    ;; soon.
    sub x3, x20, x21
    cmp x3, #content_len_match_len
    b.lt pcl_done

    ;ldr x0, [x19, x21]
    add x0, x19, x21
    adr_l x1, content_len_match_str
    mov x2, #content_len_match_len
    bl streqn_i

    cmp x0, #0
    b.eq Lscan_again

    ;; if we're here, it was a match!
    ;; let's just make sure the sentinel isn't already set, as in, we haven't
    ;; already found a separate content-length header field, and this is a
    ;; duplicate.
    cmp x22, #-1
    b.ne pcl_malformed

    add x21, x21, #content_len_match_len
    cmp x21, x20
    b.ge pcl_done

    ;; make sure "content-length" is followed immediately by a ":", otherwise
    ;; reject it.
    ldrb w2, [x19, x21]
    cmp w2, #':'
    b.ne Lscan_again

Lskip_ws:
    ;; gotta bounds check on every byte. got i hate string parsing!
    add x21, x21, #1
    cmp x21, x20
    b.ge pcl_done

    ldrb w2, [x19, x21]
    cmp w2, #' '
    b.eq Lskip_ws
    cmp w2, #'\t'
    b.eq Lskip_ws
    ;; got past the whitespace

    ;; get the length of numbers
    mov x0, x21
    mov x1, #0
Lget_cl_len:
    ldrb w2, [x19, x0]
    cmp w2, #'0'
    b.lt Lgot_cl_len
    cmp w2, #'9'
    b.gt Lgot_cl_len

    add x1, x1, #1
    add x0, x0, #1
    cmp x0, x20
    b.ge pcl_done

    b Lget_cl_len

Lgot_cl_len:
    ;; now x1 is the number of digits following "content-length:", after
    ;; whitespace.
    ;; but first, if the next character is *not* \r, then it means content
    ;; length has some string like "124afoo", which is invalid.
    cmp w2, #'\r'
    b.ne pcl_malformed

    ;; if the header ends like "content-length: foo" with nothing after, like
    ;; no \r\n\r\n, it's malformed. this isn't a strict check -- just makes
    ;; sure the end of content-length is not the last byte of the header.
    cmp x0, x20
    b.ge pcl_malformed

    ;; ensure x1 has a reasonable size to prevent overflows. 20 characters
    cmp x1, #20
    b.gt pcl_body_too_large

    ;; load the string + pointer index into x0
    mov x0, x19
    add x0, x0, x21
    ;; x1 is still set
    bl atoi_n
    b.cs pcl_malformed

    ;; let's also cap it at 1GB (by default). change MAX_BODY_SIZE at the top
    ;; of the file to customize.
    mov x1, #MAX_BODY_SIZE
    cmp x0, x1
    b.hi pcl_body_too_large

    ;; now x0 should be the length!
    mov x22, x0

    ;; fall through to Lscan_again
Lscan_again:
    add x21, x21, #1
    b pcl_scan

pcl_done:
    cmp x22, #-1
    b.eq pcl_err

    mov x0, x22
    cmn xzr, xzr ; clears carry bit
    b pcl_epilogue

pcl_body_too_large:
    cmp xzr, xzr ; sets carry bit
    mov x0, #2 ; 2 means Content-Length: X value is too large
    b pcl_epilogue

pcl_malformed:
    cmp xzr, xzr ; sets carry bit
    mov x0, #1 ; 1 means malformed header
    b pcl_epilogue

pcl_err:
    cmp xzr, xzr ; sets carry bit
    mov x0, #0 ; 0 means other error, like no content-length found
    ;; fall through

pcl_epilogue:
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #48
    ret

;; input
;; x0 -> HTTP header from client ("GET /...")
;; 
;; return
;; x0 -> string containing requested file name
;; x1 -> length of said file name
;;
;; clobbers x0, x1, x2, x3
parse_path:
    ;; preserve link register so we can bl to other functions properly
    stp x29, x30, [sp, #-16]!
    mov x1, #0
    mov x2, #1 ;; just has to be non-null, previous byte to make sure a space
               ;; precedes the '/'
;; this is basically strchr
Lstrchr_loop:
    ;; load the current byte at the string pointer, and check if it's /
    ldrb w3, [x0]
    cmp w3, #'/'
    b.eq Lchar_found

    ;; if we haven't reached a / in the first 16 bytes, we'll fail
    cmp x1, #16
    b.eq Lno_match

    ;; if we reached a NULL byte in the first 16 bytes, it's definitely a
    ;; weird request header. so, let's just fail.
    cmp w3, #0
    b.eq Lno_match

    ;; if we got here, we gotta loop again. < 16 bytes in, no / reached, and no
    ;; NULL byte reached. increment string index and loop
    add x0, x0, #1 ;; increment the string pointer
    add x1, x1, #1 ;; increment the byte counter so we can quit at 16 bytes
    
    ;; save previous byte so we can check for preceding ' '
    mov w2, w3
    b Lstrchr_loop

;; If we got here, we found a '/'. let's make sure the preceding byte -- stored
;; in x2, is a ' ' so we only match ' /'. that way we avoid 'HTTP/1.1'
;; "matching".
Lchar_found:
    cmp w2, #' '
    b.ne Lno_match

    add x0, x0, #1 ;; skip past the '/' which we're currently on

    ;; zero out x2, which is used as both an index into filename_buf and as a
    ;; relative index (x2 + 4, to skip the starting "GET ") into the header
    mov x2, #0

    ;; load in filename_buf to x1
    adr_l x1, filename_buf

    mov x8, x3
    mov x7, x2
    mov x6, x1
    mov x5, x0

    mov x0, x6
    adr_l x1, www_prefix
    mov x2, www_prefix_len
    bl memcpy

    mov x0, x5
    mov x1, x6
    mov x2, x7
    mov x3, x8
    mov x4, www_prefix_len

Lfilename_loop:
    cmp x4, filename_buf_size ; bounds check
    b.ge Lno_match

    ldrb w3, [x0, x2] ; load byte from header+index
    cbz w3, Lno_match ; is it NULL? go to 4f if it is

    cmp w3, #' ' ; is it a space?
    b.eq Lfilename_done ; we're done once we reach a space

    cmp w3, #'\r'
    b.eq Lno_match

    cmp w3, #'\n'
    b.eq Lno_match

    ;; ok, we're not done
    strb w3, [x1, x4] ; copy byte to filename_buf+index
    add x4, x4, #1 ; increment the filename index
    add x2, x2, #1 ; increment the header index
    b Lfilename_loop

Lfilename_done:
    ;; is the length the same as the www/ prefix? if it is, we didn't actually
    ;; get a file.
    mov x5, www_prefix_len
    cmp x4, x5
    b.eq Lempty_filename

    strb wzr, [x1, x4] ;; null-terminate filename_buf
    mov x0, x1 ; we want x0 to point to the filename string
    mov x1, x4 ; x1 is the length of the filename
    b Lparse_return

Lempty_filename:
    mov x5, x1 ; save filename_buf in x5
    mov x2, www_prefix_len

    ; the default file name, "index.html", is only for GET requests. if it's a
    ; DELETE/PUT/POST/anything else, just "www/" is enough. we'll let the
    ; system handle the error elsewhere if it causes problems.
    cmp x20, GET_REQ_ID
    b.ne Lnot_get

    adr_l x0, filename_buf
    ;; skip past the www/
    add x0, x0, x2

    adr_l x1, default_file
    mov x2, default_file_len
    bl memcpy

    strb wzr, [x0] ;; null terminate

    mov x0, x5
    mov x1, www_prefix_len
    mov x2, default_file_len
    add x1, x1, x2

    b Lparse_return
Lnot_get:
    mov x0, x5
    mov x1, www_prefix_len
    b Lparse_return

;; no match was when we were parsing the header for request type. since we cant
;; find a file without a /, just return NULL
Lno_match:
    mov x0, #0
    mov x1, #0
    b Lparse_return

Lparse_return:
    ;; restore the link register and ret
    ldp x29, x30, [sp], #16
    ret

;; input
;; x0 -> string
;; x1 -> length
;;
;; return
;; x1 -> index of the first byte after the header
parse_header_end:
    adr_l x2, header_end
    mov x5, #0
    mov x6, #0
Lheader_end_loop:
    cmp x5, x1
    b.ge Lno_end_found

    ldrb w3, [x0, x5]
    ldrb w4, [x2, x6]

    cmp w3, w4
    b.eq Lcorrect_char

    b Lincorrect_char

Lcorrect_char:
    add x6, x6, #1

    cmp x6, #4 ; length of \r\n\r\n
    b.ge Lend_found

    add x5, x5, #1
    b Lheader_end_loop

Lincorrect_char:
    mov x6, #0
    cmp w3, #'\r' ; this \r starts a new potential match, eg, \r\n\r>\r<\n\r\n
    b.ne 2f
    mov x6, #1
2:
    add x5, x5, #1
    b Lheader_end_loop

Lend_found:
    add x1, x5, #1
    ret

Lno_end_found:
    mov x1, #0
    ret


;; case insensitive streqn
;; input
;; x0 -> str1
;; x1 -> str2
;; x2 -> max length
;;
;; returns
;; x0 -> 1 if match, 0 if doesn't match
streqn_i:
    ;; load bytes
    ldrb w3, [x0]
    ldrb w4, [x1]
    ;; make them both lowercase by OR'ing with 0x20, doesn't affect other
    ;; characters than alphabetical.
    orr w3, w3, #0x20
    orr w4, w4, #0x20
    cmp w3, w4
    b.ne Lstreqn_i_no_match

    cbz w3, Lstreqn_i_match ; both equal and both NULL = end of string = match

    ;; if we've reached the end, it's a match yeah?
    subs x2, x2, #1
    b.eq Lstreqn_i_match

    add x0, x0, #1
    add x1, x1, #1
    b streqn_i

Lstreqn_i_match:
    mov x0, #1
    ret

Lstreqn_i_no_match:
    mov x0, #0
    ret

;; input
;; x0 -> str1
;; x1 -> str2
;; x2 -> max length
;;
;; returns
;; x0 -> 1 if match, 0 if doesn't match
streqn:
    ldrb w3, [x0]
    ldrb w4, [x1]
    cmp w3, w4
    b.ne Lstreqn_no_match

    cbz w3, Lstreqn_match ;; both equal and both NULL = end of string = match

    ;; if we've reached the end, it's a match yeah?
    subs x2, x2, #1
    b.eq Lstreqn_match

    add x0, x0, #1
    add x1, x1, #1
    b streqn

Lstreqn_match:
    mov x0, #1
    ret

Lstreqn_no_match:
    mov x0, #0
    ret

L400: b reply_400
