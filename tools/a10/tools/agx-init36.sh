#!/bin/busybox sh
# Historical hook: give register 0x480 a mapped zero page.
. /run/agx-init35.sh
# Initially misidentified as context state; fault controls 40/41 established
# that 0x480 is the actual STREAM base. Thus this parses zeros as a kernel.
# Hook 42 corrects the addresses. VA 0x202000 is in the owned 16 KiB page.
put32 scratch 0x5b010 0x202000
