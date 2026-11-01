#!/bin/busybox sh
# BEFORE_INIT hook: finalize+end CPU-only microsequence with completion stamp.
# The unit status 3 takes the cancellation path: NO GPU work is launched.
. /run/agx-init23.sh
put32 scratch 0x54000 12
put32 scratch 0x54004 0x146000
put32 scratch 0x5401c 0x145000
put32 scratch 0x54020 1
put32 scratch 0x54028 0x146100
put32 scratch 0x5600c 3
put32 scratch 0x54030 2
put32 scratch 0x2f1ec 0x34
