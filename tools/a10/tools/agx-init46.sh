#!/bin/busybox sh
# BEFORE_INIT hook: give the cache flush its actual mapped GPU scratch address.
. /run/agx-init44.sh
# fw 0x1bb0a copies Q[0:8] -> local 0x8dd50; 0x597c..0x599c programs
# that value into RGX+0xe240. Previously Q was zero, so flush wrote to VA 0.
# This uses the final 4 KiB of our existing owned 16 KiB GPU data page.
# Unlike diagnostic hook 45, GPU VA 0 remains UNMAPPED.
put32 scratch 0x6000 0x203000
put32 scratch 0x6004 0
