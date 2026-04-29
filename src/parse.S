;; parse.S
;; HTTP request parsing: path, header end, content-length. plus tmp-file
;; name generation, string compares, and the do_path_checks pipeline that
;; ties the path-validation steps together.

#include "defs.S"

.global parse_header_end
.global parse_content_length
.global make_tmp_file
.global do_path_checks

;; this is PATH_MAX
.equ filename_buf_size, 4096
;; (PATH_MAX + some extra bytes for tmp stuff)
.equ filename_buf_tmp_size, filename_buf_size + 64
;; accept files of up to 1GB for PUT. change this if you want larger files.
.equ MAX_BODY_SIZE, 1024 * 1024 * 1024

.data
header_end: .ascii "\r\n\r\n"
.equ header_end_len, . - header_end

content_len_match_str: .ascii "content-length"
.equ content_len_match_len, 14

www_prefix: default_dir ;; default_dir from defs.S
.equ www_prefix_len, . - www_prefix

default_file: .ascii "index.html"
.equ default_file_len, . - default_file

tmp_prefix: default_dir
            .ascii ".ymawky_tmp_"
.equ tmp_prefix_len, . - tmp_prefix
.align 3 ;; tmp_prefix length is odd, realign for the .quad below
tmp_prefix_len_val: .quad tmp_prefix_len

.bss
;; probably way too defensive, but can't hurt, eh?
filename_buf: .skip filename_buf_size + 1
.align 3 ;; fix broken alignment again
filename_buf_tmp: .skip filename_buf_tmp_size + 1
.align 3

.text
.align 2

;; take a filename, and create a temporary file for PUT.
;; eg, "test.txt" -> ".ymawky_tmp_<pid>", then that temp file gets written to,
;; and on success, renamed to "test.txt", or unlinked on fail.
;; input
;; none
;;
;; return
;; x0 -> generated temporary filename
;; x1 -> length of generated temporary filename
make_tmp_file:
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]

    mov x23, #0
    movz x24, #filename_buf_tmp_size

    ;; preemptively increment the counter to account for the prefix
    mov x22, #tmp_prefix_len
    add x23, x23, x22
    ;; quit if it's too big. we don't want to accidentally write into other
    ;; memory
    cmp x23, x24
    b.hi mtf_err 

    ;; copy tmp_prefix to filename_buf_tmp
    adr_l x0, filename_buf_tmp
    adr_l x1, tmp_prefix
    mov x2, #tmp_prefix_len
    bl memcpy
    mov x21, x0 ; save pointer with offset from memcpy

    ;; getpid()
    mov x16, SYS_getpid
    svc #0x80
    ;; now x0 contains the pid

    ;; itoa() on getpid()
    bl itoa
    ;; x0 -> string, x1 -> length of string
    mov x22, x1

    ;; preemptively increment the counter, and bounds check, for return once
    ;; more
    add x23, x23, x22
    cmp x23, x24
    b.hi mtf_err

    ;; copy string of pid to the end of filename_buf_tmp
    mov x2, x1
    mov x1, x0
    mov x0, x21 ; load pointer with offset
    bl memcpy

    ;; one last bounds check, preemptively, for the NULL terminator. then add
    ;; it.
    add x23, x23, #1
    cmp x23, x24
    b.hi mtf_err
    strb wzr, [x0]

    ;; load data for returning. make x0 a pointer to the start of
    ;; filename_buf_tmp, and x1 the total length of the file (-1 to get rid of
    ;; the NULL byte from length).
    adr_l x0, filename_buf_tmp
    sub x1, x23, #1

    cmn xzr, xzr ; clear carry bit just in case! probably unneeded.
    b mtf_epilogue

mtf_err:
    cmp xzr, xzr ; sets carry bit
    ;; return NULLs
    mov x0, #0
    mov x1, #0
    ;; fallthrough

mtf_epilogue:
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #64
    ret


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

Lskip_leading_zeroes:
    ldrb w2, [x19, x21]
    cmp w2, #'0'
    b.ne 1f ;; not a zero so lets get the content length for real!

    ;; hm it is a zero. is it the last zero? peak at da next char
    add x3, x21, #1
    cmp x3, x20
    b.ge 1f ; if it's the end of the string, don't skip this zero

    ldrb w3, [x19, x3]
    cmp w3, #'0'
    b.lt 1f ;; if the next char is < 0, like \r, keep it and count
    cmp w3, #'9'
    b.gt 1f ;; likewise if the char is > 9

    ;; if we're here, the current char is 0 and the next char is also a digit.
    ;; skip it to skip leading zeroes!
    add x21, x21, #1
    b Lskip_leading_zeroes

1:
    mov x0, x21 ; x21 points to the true start of the number, after leading 0s
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
    ;; whitespace. if it's 0, that means empty content length. bad!
    cbz x1, pcl_malformed
    ;; but first, if the next character is *not* \r, then it means content
    ;; length has some string like "124afoo", which is invalid.
    cmp w2, #'\r'
    b.ne pcl_malformed

    ;; if the header ends like "content-length: foo" with nothing after, like
    ;; no \r\n\r\n, it's malformed. this isn't a strict check -- just makes
    ;; sure the end of content-length is not the last byte of the header.
    cmp x0, x20
    b.ge pcl_malformed

    ;; ensure x1 has a reasonable size to prevent overflows. 18 characters
    cmp x1, #18
    b.ge pcl_body_too_large

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
;; x1 -> boolean, if 1/true, default to "index.html" default filename. if
;;       0/false, do not give a default filename.
;; 
;; return
;; x0 -> string containing requested file name
;; x1 -> length of said file name
;;
;; clobbers x0, x1, x2, x3
parse_path:
    ;; preserve link register so we can bl to other functions properly
    stp x29, x30, [sp, #-32]!
    stp x20, x21, [sp, #16]
    mov x20, x1 ;; save bool option in x20.

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

    ;; load in filename_buf to x1
    adr_l x1, filename_buf

    ;; gotta save x0 and x1, since memcpy changes the pointers
    stp x0, x1, [sp, #-16]!
    mov x0, x1
    adr_l x1, www_prefix
    mov x2, www_prefix_len
    bl memcpy
    ldp x0, x1, [sp], #16

    ;; zero out x2, which is used as both an index into filename_buf and as a
    ;; relative index (x2 + 4, to skip the starting "GET ") into the header
    mov x2, #0
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
    cbz x20, Lno_default_file

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
Lno_default_file:
    mov x0, x5
    mov x1, www_prefix_len
    b Lparse_return

;; no match was when we were parsing the header for request type. since we cant
;; find a file without a /, just return NULL
Lno_match:
    mov x0, #0
    mov x1, #0
    cmp xzr, xzr
    b 1f

Lparse_return:
    cmn xzr, xzr ; clear carry in case. it gets set in the other error paths.
1:
    ;; restore the link register and ret
    ldp x20, x21, [sp, #16]
    ldp x29, x30, [sp], #32
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


;; decode hex/safety check/traversal check for a given path.
;; input
;; x0 -> boolean for parse_path, should a default file be provided if none is
;;       given? 0/false, no default (PUT, DELETE). 1/true, yes default to
;;       index.html (GET, HEAD)
;;
;; output
;; none -- responds with 400 or other error codes if needed.
do_path_checks:
    stp x29, x30, [sp, #-16]!

    mov x1, x0
    adr_l x0, buf
    bl parse_path
    b.cs L400

    ;; x0 is already path, x1 is already path length
    bl decode_url
    cbz x0, L400

    str_l x0, filename_str
    str_l x1, filename_len
    bl check_path_safety
    cbz x0, L400

    ldr_l x0, filename_str
    ldr_l x1, filename_len
    bl check_path_traversal
    cbz x0, L400

    ldr_l x0, filename_len
    ldr_l x1, tmp_prefix_len_val
    cmp x0, x1
    b.lt 2f

    ldr_l x0, filename_str
    adr_l x1, tmp_prefix
    ldr_l x2, tmp_prefix_len_val
    bl streqn_i
    cbnz x0, L403
2:
    ldp x29, x30, [sp], #16
    ret


;; trampolines for conditional branches to reply_* in errors.S (which is too
;; far for b.cond / cbz to reach directly).
L400: b reply_400
L403: b reply_403
L500: b reply_500
