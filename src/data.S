;; data.S
;; shared data referenced by multiple files

#include "defs.S"

.global buf
.global clientfd

.bss
;; + 1 so we can NULL terminate, even if content is BUF_SIZE bytes long
buf:                .skip BUF_SIZE + 1
clientfd:           .skip 8
