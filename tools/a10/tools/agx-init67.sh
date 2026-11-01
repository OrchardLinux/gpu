#!/bin/busybox sh
# BEFORE_INIT: negative control for 66. Same dispatch, but the PDS data points
# DOUTU at USC offset 0x4000 -> unmapped 0x300004000. A USC instruction-fetch
# fault there proves 66's completion executed the shader, not just the PDS.
. /run/agx-init66.sh
put32 scratch 0x84800 0x00004000
