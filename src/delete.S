;; delete.S
;; DELETE request handler. idempotent: missing files reply 204.

#include "defs.S"

.global delete

.text
.align 2

;; handle "DELETE /" method.
;; input
;; none, uses .bss data
;;
;; output
;; none, replies either 204 or some error code and quits.
delete:
    bl do_path_checks
    ldr_l x0, filename_str

    bl stat_path
    cbnz x0, Ldelete_stat_failed
    cb ne, w1, #S_IFREG, L403

    mov x16, SYS_unlink
    ldr_l x0, filename_str
    svc #0x80
    b.cs Lunlink_failed

    b reply_204

;; these are really the same case, tbqh. the errno checks are the same. i use
;; different label names for clarity when reading hehe
Ldelete_stat_failed:
Lunlink_failed:
    ;; if the file doesn't exist (or was previously deleted), just reply 204
    ;; since DELETE is idempotent.
    cb eq, x0, #ENOENT, L204

    ;; if it's a dir, say it's not allowed. this could be 405, but i don't
    ;; want to build Allow: headers properly, lol. at least yet.
    cb eq, x0, #EISDIR, L403
    ;; other various 403s.
    cb eq, x0, #EACCES, L403
    cb eq, x0, #EPERM, L403
    cb eq, x0, #EROFS, L403
    ;; file is busy/conflict
    cb eq, x0, #EBUSY, L409

    ;; just default to 500
    b reply_500

;; trampolines for conditional branches across files.
L204: b reply_204
L403: b reply_403
L409: b reply_409
