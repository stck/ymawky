#include "defs.S"

.global buf
.global header_len
.global clientfd
.global filename_str
.global filename_len

.bss
;; + 1 so we can NULL terminate, even if content is BUF_SIZE bytes long
buf:        .skip BUF_SIZE + 1
.align 3 ;; + 1 breaks alignment
header_len:   .skip 8
clientfd:     .skip 8
filename_str: .skip 8
filename_len: .skip 8
