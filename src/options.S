#include "defs.S"

.global options

.text
options:
    ;; do not default to index.html
    mov x0, #0
    bl do_path_checks

    ldr_l x0, filename_str
    ldrb w1, [x0]
    cmp w1, #'*'
    b.eq L204

    ;; x0 is currently set
    bl stat_path
    cbnz x0, Lhfs_err
    cmp w1, #S_IFREG
    b.eq L403

    b reply_204

Lhfs_err: b handle_fs_error
L204: b reply_204
L403: b reply_403
